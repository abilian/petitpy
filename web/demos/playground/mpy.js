// Decode and disassemble a MicroPython `.mpy` v6 container.
//
// The playground compiles by running `petitpy --emit-mpy` in the same
// one-shot WASI flow it uses to run programs, then decodes the base64 that
// lands on stdout. Doing the decoding here rather than in Zig keeps it out of
// the wasm binary, which has a size budget; JS does not.
//
// The layout mirrors projects/pyfront/tests/mpy_reader.py, which is the
// tested reference. Every length is declared before its payload, so walking
// the whole file and landing exactly on the final byte is a strong check:
// a truncated payload or a mis-encoded var-int knocks the cursor out of step.

import {
  OPCODES,
  MULTI,
  formatOf,
  FORMAT_QSTR,
  FORMAT_VAR_UINT,
  FORMAT_OFFSET,
} from "./opcodes.js";
import { STATIC_QSTRS } from "./qstrs.js";

// The signed/unsigned split in the jump family, mirroring emit.zig:1226.
const byName = (name) => Number(Object.keys(OPCODES).find((k) => OPCODES[k] === name));
const POP_JUMP_IF_FALSE = byName("POP_JUMP_IF_FALSE");
const UNWIND_JUMP = byName("UNWIND_JUMP");

const OBJ_NONE = 1,
  OBJ_FALSE = 2,
  OBJ_TRUE = 3,
  OBJ_ELLIPSIS = 4;
const OBJ_STR = 5,
  OBJ_BYTES = 6,
  OBJ_INT = 7,
  OBJ_FLOAT = 8,
  OBJ_TUPLE = 10;

export class Malformed extends Error {}

class Cursor {
  constructor(bytes) {
    this.b = bytes;
    this.i = 0;
  }
  byte() {
    if (this.i >= this.b.length) throw new Malformed("ran off the end of the buffer");
    return this.b[this.i++];
  }
  // The inverse of bytecode.uint: 7 bits a byte, high bit continues.
  uint() {
    let v = 0;
    let n = this.byte();
    while (n & 0x80) {
      v = (v << 7) | (n & 0x7f);
      n = this.byte();
    }
    return (v << 7) | n;
  }
  take(n) {
    if (this.i + n > this.b.length) throw new Malformed("payload runs past the end");
    return this.b.subarray(this.i, (this.i += n));
  }
}

const TEXT = new TextDecoder();

function readObj(c) {
  const tag = c.byte();
  if (tag === OBJ_NONE) return null;
  if (tag === OBJ_TRUE) return true;
  if (tag === OBJ_FALSE) return false;
  if (tag === OBJ_ELLIPSIS) return "...";
  if (tag === OBJ_TUPLE) {
    const n = c.uint();
    return Array.from({ length: n }, () => readObj(c));
  }
  if (tag === OBJ_STR || tag === OBJ_BYTES || tag === OBJ_INT || tag === OBJ_FLOAT) {
    const payload = c.take(c.uint());
    if (tag === OBJ_STR || tag === OBJ_BYTES) {
      // The terminator the loader skips; its absence means every entry
      // after this one decodes one byte late.
      if (c.byte() !== 0) throw new Malformed("payload is not NUL-terminated");
      return tag === OBJ_STR ? TEXT.decode(payload) : payload;
    }
    const text = TEXT.decode(payload);
    return tag === OBJ_INT ? BigInt(text) : Number(text);
  }
  throw new Malformed(`unknown object tag ${tag}`);
}

function opName(op) {
  if (op in OPCODES) return OPCODES[op];
  for (const m of MULTI) {
    // `excess` shifts the operand negative: small ints start at -16, so
    // 0x70 is the constant -16 and 0x80 is 0.
    if (op >= m.base && op < m.base + m.num) return `${m.name} ${op - m.base - m.excess}`;
  }
  return `<0x${op.toString(16)}>`;
}

/// Walk one code object's bytecode, after its prelude.
function disassemble(code, qstrs) {
  const out = [];
  const c = new Cursor(code);
  while (c.i < code.length) {
    const at = c.i;
    const op = c.byte();
    let arg = "";
    switch (formatOf(op)) {
      case FORMAT_QSTR: {
        const q = c.uint();
        arg = qstrs[q] !== undefined ? `${q} (${qstrs[q]})` : String(q);
        break;
      }
      case FORMAT_VAR_UINT:
        arg = String(c.uint());
        break;
      case FORMAT_OFFSET: {
        // Variable width (emit.zig writeBytecodeByteLabel): one byte when
        // the offset fits, two when it does not, and the high bit of the
        // first byte says which. Signed offsets carry a bias so they can
        // point backwards — and only the jump family below
        // POP_JUMP_IF_FALSE is signed; FOR_ITER and the *_OR_POP family
        // are unsigned and never go back.
        const signed = op <= POP_JUMP_IF_FALSE;
        const b0 = c.byte();
        let delta;
        if (b0 & 0x80) {
          delta = ((b0 & 0x7f) | (c.byte() << 7)) - (signed ? 0x4000 : 0);
        } else {
          delta = b0 - (signed ? 0x40 : 0);
        }
        arg = String(delta);
        // UNWIND_JUMP carries the number of exception levels to unwind in
        // one more byte after the offset. Not consuming it desyncs every
        // instruction that follows.
        if (op === UNWIND_JUMP) arg += ` unwind=${c.byte()}`;
        break;
      }
      default:
        break;
    }
    out.push({ at, op, name: opName(op), arg });
  }
  return out;
}

/// Inverse of `prelude_sig`. The first byte is xSSSSEAA; continuation
/// bytes carry the rest of the state size, exception depth, flags and
/// argument counts. Only n_state is surfaced — it is the frame size, the
/// one number that says how much stack a scope needs.
function preludeSig(c) {
  let z = c.byte();
  let s = (z >> 3) & 0xf;
  let e = (z >> 2) & 1;
  let shiftS = 4;
  while (z & 0x80) {
    z = c.byte();
    s |= ((z >> 4) & 0x7) << shiftS;
    e |= ((z >> 3) & 1) << 1;
    shiftS += 3;
  }
  return { nState: s + 1, nExc: e };
}

/// Inverse of `prelude_size`. Each byte is xIIIIIIC, little-endian: six
/// bits of the info-block length and one bit of the cell count.
function preludeSize(c) {
  let nInfo = 0;
  let nCell = 0;
  let shiftI = 0;
  let shiftC = 0;
  let z;
  do {
    z = c.byte();
    nInfo |= ((z >> 1) & 0x3f) << shiftI;
    nCell |= (z & 1) << shiftC;
    shiftI += 6;
    shiftC += 1;
  } while (z & 0x80);
  return { nInfo, nCell };
}

/// One code object: its prelude header, its bytecode, and its children.
function readRawCode(c, qstrs) {
  const header = c.uint();
  const size = header >> 3;
  const hasChildren = (header >> 2) & 1;
  const body = c.take(size);

  // Prelude layout (see pyfront emit/bytecode.py, the tested encoders):
  //     sig | size | info(nInfo) | closure(nCell) | bytecode
  // Neither field is a plain var-int, so both need their own reader.
  const p = new Cursor(body);
  const { nState, nExc } = preludeSig(p);
  const { nInfo, nCell } = preludeSize(p);
  const bytecode = body.subarray(p.i + nInfo + nCell);

  const children = [];
  if (hasChildren) {
    const n = c.uint();
    for (let i = 0; i < n; i++) children.push(readRawCode(c, qstrs));
  }
  return { nState, nExc, bytes: size, ops: disassemble(bytecode, qstrs), children };
}

/// Parse a whole `.mpy`. Throws Malformed on anything inconsistent.
export function parseMpy(bytes) {
  if (bytes.length < 4) throw new Malformed("shorter than the header");
  if (bytes[0] !== 0x4d) throw new Malformed("not a .mpy (bad magic)");
  const version = bytes[1];

  const c = new Cursor(bytes);
  c.i = 4;
  const nQstr = c.uint();
  const nObj = c.uint();

  // The low bit of the prefix says which kind: a *new* string carries its
  // bytes plus a NUL, a *static* one is just an id into the interpreter's
  // built-in pool and carries nothing. pyfront only ever writes new
  // strings, so its reader has no static case; the Zig writer emits both.
  const qstrs = [];
  for (let i = 0; i < nQstr; i++) {
    const prefix = c.uint();
    if (prefix & 1) {
      const id = prefix >> 1;
      qstrs.push(STATIC_QSTRS[id] ?? `#${id}`);
      continue;
    }
    const name = c.take(prefix >> 1);
    if (c.byte() !== 0) throw new Malformed("qstr is not NUL-terminated");
    qstrs.push(TEXT.decode(name));
  }

  const objs = [];
  for (let i = 0; i < nObj; i++) objs.push(readObj(c));

  const top = readRawCode(c, qstrs);
  if (c.i !== bytes.length) {
    throw new Malformed(`${bytes.length - c.i} trailing byte(s) after the code tree`);
  }
  return { version, smallIntBits: bytes[3], qstrs, objs, top, size: bytes.length };
}

export function base64ToBytes(b64) {
  const bin = atob(b64.trim());
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

// petitpy — browser demo
//
// Loads zig-out/bin/petitpy.wasm (wasm32-wasi, ReleaseSmall) and runs it
// against a virtual filesystem where /source.py holds the user's textarea.
// stdin (fd 0) is fed from a second textarea; stdout + stderr are captured.
//
// Features:
//   - Examples dropdown          (web/examples.js)
//   - localStorage script library (Save / Load / Delete by name)
//   - Share via URL fragment      (#code=<base64url>)
//   - stdin pane                  (piped to fd 0 via OpenFile)

import {
  WASI,
  File,
  Directory,
  OpenFile,
  PreopenDirectory,
  ConsoleStdout,
} from "https://cdn.jsdelivr.net/npm/@bjorn3/browser_wasi_shim@0.4.2/dist/index.js";

import { EXAMPLES, EXAMPLE_ORDER } from "./examples.js";
import { fetchPackage, listCached, clearCache } from "./zpip-browser.js";
import { makeJsBridge } from "../../lib/js-bridge.js";
import { addFile } from "../../lib/wasi-fs.js";
import { parseMpy, base64ToBytes } from "./mpy.js";
import { GALLERY } from "./gallery.js";
import { highlight, gutter } from "../../lib/highlight.js";

const $src = document.getElementById("src");
const $stdin = document.getElementById("stdin");
const $run = document.getElementById("run");
const $share = document.getElementById("share");
const $out = document.getElementById("out");
const $status = document.getElementById("status");
const $size = document.getElementById("wasm-size");
const $example = document.getElementById("example");
const $saved = document.getElementById("saved");
const $save = document.getElementById("save");
const $delete = document.getElementById("delete");
const $saveName = document.getElementById("save-name");
const $packages = document.getElementById("packages");
const $cached = document.getElementById("cached");
const $clearCache = document.getElementById("clear-cache");
const $dis = document.getElementById("dis");
const $bcSize = document.getElementById("bc-size");
const $hl = document.getElementById("hl");
const $gutter = document.getElementById("gutter");

const STORAGE_KEY = "petitpy:scripts:v1";

let wasmModule = null;

// ---- status -----------------------------------------------------------------

function setStatus(text, kind = "") {
  $status.textContent = text;
  $status.classList.remove("err", "ok");
  if (kind) $status.classList.add(kind);
}

// ---- base64url for the URL fragment ----------------------------------------
// We use base64url (no padding) so the fragment stays URL-safe and short.

function encodeShare(text) {
  const bytes = new TextEncoder().encode(text);
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function decodeShare(b64url) {
  let b64 = b64url.replace(/-/g, "+").replace(/_/g, "/");
  while (b64.length % 4) b64 += "=";
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return new TextDecoder().decode(bytes);
}

// ---- localStorage -----------------------------------------------------------

function loadStore() {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return {};
    const obj = JSON.parse(raw);
    return obj && typeof obj === "object" ? obj : {};
  } catch {
    return {};
  }
}

function saveStore(obj) {
  localStorage.setItem(STORAGE_KEY, JSON.stringify(obj));
}

function refreshSavedDropdown(selectName = "") {
  const store = loadStore();
  const names = Object.keys(store).sort();
  $saved.innerHTML = '<option value="">(none)</option>';
  for (const name of names) {
    const opt = document.createElement("option");
    opt.value = name;
    opt.textContent = name;
    if (name === selectName) opt.selected = true;
    $saved.appendChild(opt);
  }
  $delete.disabled = names.length === 0 || !$saved.value;
}

// ---- editor overlay ---------------------------------------------------------
//
// The coloured text is a <pre> behind a transparent <textarea>. They share
// font metrics and padding, so the only thing keeping them aligned is that
// highlight() returns the source unchanged apart from <span> wrappers — and
// that the two scroll together.

function paintEditor() {
  $hl.innerHTML = highlight($src.value);
  $gutter.innerHTML = gutter($src.value);
  syncScroll();
}

function syncScroll() {
  $hl.scrollTop = $src.scrollTop;
  $hl.scrollLeft = $src.scrollLeft;
  $gutter.scrollTop = $src.scrollTop;
}

// ---- examples dropdown ------------------------------------------------------

function populateExamples() {
  for (const name of EXAMPLE_ORDER) {
    const opt = document.createElement("option");
    opt.value = name;
    opt.textContent = name;
    $example.appendChild(opt);
  }
}

// ---- run loop ---------------------------------------------------------------

async function loadWasm() {
  setStatus("Fetching petitpy.wasm…");
  // Cache-buster on wasm so dev iteration always picks up a fresh build.
  const _v = Date.now();
  const resp = await fetch(`../../petitpy.wasm?v=${_v}`, { cache: "no-store" });
  if (!resp.ok) throw new Error(`fetch failed: ${resp.status}`);
  const blob = await resp.clone().blob();
  $size.textContent = `${Math.round(blob.size / 1024)} KB`;
  wasmModule = await WebAssembly.compileStreaming(resp);
  setStatus("Ready.", "ok");
  $run.disabled = false;
  $run.textContent = "Run";
  // Compile straight away, and directly rather than through the debounce:
  // a hidden or throttled page may not run timers at all (headless Chromium
  // does not), and the pane being populated on arrival is not something to
  // leave to a timer.
  await showBytecode();
}

// Parse the Packages textarea: split on whitespace, drop empties + comments.
function parsePackages() {
  if (!$packages) return [];
  return $packages.value
    .split(/\s+/)
    .map((s) => s.trim())
    .filter((s) => s && !s.startsWith("#"));
}

// Inject a small preamble so /lib is on sys.path before any user import.
// (sys.path is consulted on every import in petitpy's L1 hook.)
function withLibPreamble(source) {
  return `import sys\nif "/lib" not in sys.path: sys.path.insert(0, "/lib")\n${source}`;
}

/// One invocation of the wasm binary. `flags` go before the script path,
/// so the same flow serves both running a program and compiling it.
///
/// Deliberately does not touch $out: `run()` calls this twice — once to
/// run, once with `--emit-mpy` to compile — and the second call would
/// otherwise wipe the output the first produced.
async function runOnce(flags = []) {
  if (!wasmModule) return null;
  $run.disabled = true;

  const packages = parsePackages();
  const encoder = new TextEncoder();
  const fsMap = new Map();

  // Mount each requested package under /lib/<file-path>. Package metadata
  // already names files with the right on-disk layout (e.g. "abc.py" or
  // "urllib/parse.py"), so we prepend "lib/" and the WASI shim plus
  // petitpy's filesystem importer (PETITPY_LIB / sys.path) reach them.
  for (const pkg of packages) {
    try {
      // The compile-only pass (--emit-mpy) runs after the status says
      // "Finished"; it must not leave "Fetching…" behind.
      if (flags.length === 0) setStatus(`Fetching ${pkg}…`);
      const files = await fetchPackage(pkg, {});
      for (const f of files) {
        addFile(fsMap, `lib/${f.name}`, new File(f.content, { readonly: true }), Directory);
      }
    } catch (e) {
      setStatus(`Failed to fetch ${pkg}: ${e?.message ?? e}`, "err");
      $run.disabled = false;
      return;
    }
  }
  await refreshCachedIndicator();

  const source = packages.length > 0 ? withLibPreamble($src.value) : $src.value;
  const stdinText = $stdin.value;
  fsMap.set("source.py", new File(encoder.encode(source), { readonly: true }));

  // Virtual FS: a single preopen at "/" with source.py + mounted /lib/* inside.
  // argv[1] = "/source.py" — petitpy reads it with std.Io.Dir.cwd().readFileAllocOptions.
  const fs = new PreopenDirectory("/", fsMap);

  // stdin is fd 0. We back it with an OpenFile wrapping a readonly File holding
  // the stdin textarea bytes. fd_read returns slices, EOF on exhaustion.
  const stdinFd = new OpenFile(new File(encoder.encode(stdinText), { readonly: true }));

  // Kept apart, not merged: `--emit-mpy` prints base64 on stdout, and a
  // diagnostic on stderr would corrupt it. The run path concatenates them
  // afterwards to keep the terminal feel.
  let outText = "";
  let errText = "";
  const stdoutFd = ConsoleStdout.lineBuffered((line) => {
    outText += line + "\n";
  });
  const stderrFd = ConsoleStdout.lineBuffered((line) => {
    errText += line + "\n";
  });

  const wasi = new WASI(
    ["petitpy", ...flags, "/source.py"], // argv
    [], // env
    [
      stdinFd, // fd 0 — stdin
      stdoutFd, // fd 1 — stdout
      stderrFd, // fd 2 — stderr
      fs, // fd 3 — preopen "/"
    ],
  );

  // ADR-006 J3 — JS interop bridge. The Zig externs are declared with
  // the default `env` namespace; we register them there. The bridge's
  // `handles` table lives for the duration of one Run (recreated each
  // call — there is no Python-side persistence between Runs in the
  // playground today).
  const jsBridge = makeJsBridge();

  let exitCode = 0;
  try {
    const inst = await WebAssembly.instantiate(wasmModule, {
      wasi_snapshot_preview1: wasi.wasiImport,
      env: jsBridge.imports,
    });
    jsBridge.attachMemory(inst.exports.memory);
    jsBridge.attachExports(inst.exports);
    exitCode = wasi.start(inst);
  } catch (e) {
    errText += `\n[host error] ${e?.message ?? e}\n`;
    exitCode = -1;
  }

  $run.disabled = false;
  return { out: outText, err: errText, exitCode };
}

// ---- run ---------------------------------------------------------------------

async function run() {
  $out.textContent = "";
  $dis.textContent = "compiling…";
  setStatus("Running…");
  const r = await runOnce();
  if (!r) return;
  const buffer = r.out + r.err;
  $out.textContent = buffer.length ? buffer : "(no output)";
  if (r.exitCode === 0) {
    setStatus("Finished (exit 0).", "ok");
  } else {
    setStatus(`Finished (exit ${r.exitCode}).`, "err");
  }
  await showBytecode();
}

// ---- bytecode + size ---------------------------------------------------------

/// Compile without running, and render the .mpy the compiler produced.
///
/// This is the same one-shot WASI flow as a run, with `--emit-mpy` in argv:
/// the binary prints the container as base64 and exits, and the decoding
/// happens here rather than in Zig, where it would cost binary size.
// Recompile as you type. A compile is ~150 ms of wasm and does not run the
// program, so it is cheap enough to do on a keystroke pause — and seeing the
// bytecode move while you edit is the whole point of the pane.
//
// Trailing debounce with an in-flight guard: keystrokes during a compile
// coalesce into exactly one more compile afterwards, so a fast typist queues
// one pending run rather than a burst of them.
let compileTimer = null;
let compileGen = 0;

/// Debounced recompile, for typing. The paths that must not be missed —
/// first load, and pressing Run — call showBytecode() directly instead.
function scheduleCompile() {
  clearTimeout(compileTimer);
  compileTimer = setTimeout(() => {
    // A generation counter rather than an in-flight flag: a flag that is
    // never cleared — one compile that rejects, or never settles — wedges
    // every later keystroke silently. Here a stale result is simply
    // ignored and the next compile still runs.
    const gen = ++compileGen;
    showBytecode(() => gen === compileGen).catch((e) => {
      $dis.textContent = `compile failed: ${e?.message ?? e}`;
      $dis.classList.add("failed");
    });
  }, 400);
}

async function showBytecode(isCurrent = () => true) {
  const r = await runOnce(["--emit-mpy"]);
  if (!r || !isCurrent()) return;

  if (r.exitCode !== 0) {
    // The compiler refused. Under the nano build the message is terse
    // ("SyntaxError: invalid syntax") because that arm's error reporting
    // is, but it beats the silence this used to print.
    // MicroPython writes its traceback to stdout, so the diagnostic can
    // arrive on either stream. Nothing else is on stdout here: the base64
    // is only printed when the compile succeeds.
    $dis.textContent =
      [r.out, r.err].map((t) => t.trim()).find(Boolean) || `compile failed (exit ${r.exitCode})`;
    $dis.classList.add("failed");
    $bcSize.textContent = "does not compile";
    return;
  }
  $dis.classList.remove("failed");

  let mpy;
  try {
    mpy = parseMpy(base64ToBytes(r.out));
  } catch (e) {
    $dis.textContent = `could not decode the .mpy: ${e?.message ?? e}`;
    $bcSize.textContent = "—";
    return;
  }

  $bcSize.textContent = `${mpy.size} B`;
  $dis.textContent = renderMpy(mpy);
}

function renderMpy(mpy) {
  const lines = [];
  lines.push(`.mpy v${mpy.version}   ${mpy.size} bytes   small-int ${mpy.smallIntBits} bits`);
  lines.push("");
  lines.push(`qstrs (${mpy.qstrs.length}): ${mpy.qstrs.map((q) => JSON.stringify(q)).join(" ")}`);
  if (mpy.objs.length) {
    lines.push(`consts (${mpy.objs.length}): ${mpy.objs.map((o) => String(o)).join(" ")}`);
  }
  lines.push("");

  const walk = (code, name, depth) => {
    const pad = "  ".repeat(depth);
    lines.push(`${pad}<code ${name}>  n_state=${code.nState}  ${code.bytes} bytes`);
    for (const op of code.ops) {
      lines.push(`${pad}  ${String(op.at).padStart(4)}  ${op.name}${op.arg ? " " + op.arg : ""}`);
    }
    code.children.forEach((c, i) => walk(c, `#${i}`, depth + 1));
  };
  walk(mpy.top, "module", 0);
  return lines.join("\n");
}

// ---- event wiring -----------------------------------------------------------

$run.addEventListener("click", run);

$example.addEventListener("change", async () => {
  const key = $example.value;
  if (!key) return;
  if (key.startsWith("gallery:")) {
    await loadGalleryProgram(key.slice("gallery:".length));
    return;
  }
  const src = EXAMPLES[key];
  if (src != null) {
    $src.value = src;
    paintEditor();
    scheduleCompile();
    setStatus(`Loaded example: ${key}`, "ok");
  }
});

$saved.addEventListener("change", () => {
  const name = $saved.value;
  $delete.disabled = !name;
  if (!name) return;
  const store = loadStore();
  if (name in store) {
    $src.value = store[name];
    paintEditor();
    $saveName.value = name;
    setStatus(`Loaded saved script: ${name}`, "ok");
  }
});

$save.addEventListener("click", () => {
  const name = $saveName.value.trim();
  if (!name) {
    setStatus("Enter a name to save under.", "err");
    $saveName.focus();
    return;
  }
  const store = loadStore();
  store[name] = $src.value;
  saveStore(store);
  refreshSavedDropdown(name);
  setStatus(`Saved as “${name}”.`, "ok");
});

$delete.addEventListener("click", () => {
  const name = $saved.value;
  if (!name) return;
  const store = loadStore();
  if (name in store) {
    delete store[name];
    saveStore(store);
    refreshSavedDropdown("");
    setStatus(`Deleted “${name}”.`, "ok");
  }
});

$share.addEventListener("click", async () => {
  const encoded = encodeShare($src.value);
  const url = `${location.origin}${location.pathname}#code=${encoded}`;
  // Reflect in the address bar so a copy from there also works.
  history.replaceState(null, "", `#code=${encoded}`);
  try {
    await navigator.clipboard.writeText(url);
    setStatus("Share URL copied to clipboard.", "ok");
  } catch {
    // clipboard may be blocked (file://, permissions); fall back to selection.
    setStatus("Share URL is in the address bar (clipboard blocked).", "ok");
  }
});

// ---- bootstrap --------------------------------------------------------------

function loadFromFragment() {
  const m = location.hash.match(/[#&]code=([^&]+)/);
  if (!m) return false;
  try {
    $src.value = decodeShare(m[1]);
    paintEditor();
    return true;
  } catch (e) {
    setStatus(`Bad share URL: ${e.message}`, "err");
    return false;
  }
}

// ---- cache indicator --------------------------------------------------------

// ---- gallery ----------------------------------------------------------------
//
// The curated examples stay inline and instant. The gallery is the measured
// corpus — every entry carries a `works-on=…petitpy-wasm` header that
// `make golden` wrote after running it there — and its source is fetched on
// selection rather than baked in, which would add ~608 KB to the page.

function populateGallery() {
  if (!GALLERY.length) return;
  const group = document.createElement("optgroup");
  group.label = `gallery (${GALLERY.length} programs that run on wasm)`;
  for (const [name, summary] of GALLERY) {
    const opt = document.createElement("option");
    opt.value = `gallery:${name}`;
    opt.textContent = summary ? `${name}: ${summary}` : name;
    group.appendChild(opt);
  }
  $example.appendChild(group);
}

async function loadGalleryProgram(name) {
  setStatus(`Fetching ${name}.py…`);
  try {
    const resp = await fetch(`../../gallery/${name}.py`);
    if (!resp.ok) throw new Error(`${resp.status} ${resp.statusText}`);
    // Drop the `# golden:` provenance lines: they are the corpus's
    // bookkeeping, not part of the program someone wants to read.
    const text = await resp.text();
    $src.value = text
      .split("\n")
      .filter((ln) => !ln.startsWith("# golden:"))
      .join("\n")
      .replace(/^\n+/, "");
    paintEditor();
    scheduleCompile();
    setStatus(`Loaded ${name}.py.`, "ok");
  } catch (e) {
    setStatus(`Could not load ${name}.py: ${e?.message ?? e}`, "err");
  }
}

async function refreshCachedIndicator() {
  if (!$cached) return;
  try {
    const items = await listCached();
    if (items.length === 0) {
      $cached.textContent = "Cache: (empty)";
    } else {
      const totalKb = Math.round(items.reduce((n, r) => n + (r.bytes ?? 0), 0) / 1024);
      const names = items
        .map((r) => r.package)
        .sort()
        .join(", ");
      $cached.textContent = `Cache (${totalKb} KB): ${names}`;
    }
  } catch (e) {
    $cached.textContent = `Cache: error (${e?.message ?? e})`;
  }
}

if ($clearCache) {
  $clearCache.addEventListener("click", async () => {
    try {
      await clearCache();
      setStatus("IndexedDB cache cleared.", "ok");
    } catch (e) {
      setStatus(`Clear failed: ${e?.message ?? e}`, "err");
    }
    await refreshCachedIndicator();
  });
}

populateExamples();
populateGallery();

$src.addEventListener("input", () => {
  paintEditor();
  scheduleCompile();
});
$src.addEventListener("scroll", syncScroll);
paintEditor();
refreshSavedDropdown();
const fromFragment = loadFromFragment();
if (fromFragment) setStatus("Loaded code from share URL.", "ok");

refreshCachedIndicator();

loadWasm().catch((e) => {
  setStatus(`Load failed: ${e.message}`, "err");
});

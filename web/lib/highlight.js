// A small Python highlighter for the editor overlay.
//
// The overlay trick: a <pre> painted behind a transparent <textarea>, both
// with identical font metrics and padding, so the coloured text lines up with
// the characters you type. That means this function must preserve the input
// exactly — every space, tab and newline — and may only wrap runs in <span>.
// Drop a character and the colours drift out of alignment with the caret.
//
// Deliberately a tokenizer, not a parser: the playground colours code as you
// type, including code that does not parse yet.

const KEYWORDS = new Set([
  "False",
  "None",
  "True",
  "and",
  "as",
  "assert",
  "async",
  "await",
  "break",
  "class",
  "continue",
  "def",
  "del",
  "elif",
  "else",
  "except",
  "finally",
  "for",
  "from",
  "global",
  "if",
  "import",
  "in",
  "is",
  "lambda",
  "nonlocal",
  "not",
  "or",
  "pass",
  "raise",
  "return",
  "try",
  "while",
  "with",
  "yield",
]);

// `match` and `case` are soft keywords: ordinary names everywhere except at
// the head of a statement. Colouring them unconditionally would paint
// `match = 1` as a keyword, so they are only lit when a `:` closes the line.
const SOFT_KEYWORDS = new Set(["match", "case"]);

const BUILTINS = new Set([
  "abs",
  "all",
  "any",
  "bin",
  "bool",
  "bytearray",
  "bytes",
  "callable",
  "chr",
  "dict",
  "dir",
  "divmod",
  "enumerate",
  "filter",
  "float",
  "getattr",
  "hasattr",
  "hash",
  "hex",
  "id",
  "int",
  "isinstance",
  "issubclass",
  "iter",
  "len",
  "list",
  "map",
  "max",
  "min",
  "next",
  "object",
  "oct",
  "ord",
  "pow",
  "print",
  "range",
  "repr",
  "reversed",
  "round",
  "set",
  "setattr",
  "sorted",
  "str",
  "sum",
  "super",
  "tuple",
  "type",
  "zip",
]);

const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

const wrap = (cls, text) => `<span class="t-${cls}">${esc(text)}</span>`;

/// Is this identifier a soft keyword *here*? Only at the start of a logical
/// line whose last non-space character is a colon.
function softKeywordHere(line, start) {
  return /^\s*$/.test(line.slice(0, start)) && line.trimEnd().endsWith(":");
}

export function highlight(source) {
  let out = "";
  const lines = source.split("\n");

  for (let li = 0; li < lines.length; li++) {
    const line = lines[li];
    let i = 0;
    while (i < line.length) {
      const rest = line.slice(i);

      const comment = /^#.*/.exec(rest);
      if (comment) {
        out += wrap("comment", comment[0]);
        i += comment[0].length;
        continue;
      }

      // Strings, including f/r/b prefixes. Unterminated ones still colour to
      // end-of-line, which is what you want while typing.
      const str =
        /^([fFrRbBuU]{0,2})("""[\s\S]*?"""|'''[\s\S]*?'''|"(?:\\.|[^"\\])*"?|'(?:\\.|[^'\\])*'?)/.exec(
          rest,
        );
      if (str) {
        out += wrap("str", str[0]);
        i += str[0].length;
        continue;
      }

      const num = /^\d[\w.]*/.exec(rest);
      if (num) {
        out += wrap("num", num[0]);
        i += num[0].length;
        continue;
      }

      const word = /^[A-Za-z_]\w*/.exec(rest);
      if (word) {
        const w = word[0];
        if (KEYWORDS.has(w)) out += wrap("kw", w);
        else if (SOFT_KEYWORDS.has(w) && softKeywordHere(line, i)) out += wrap("kw", w);
        else if (BUILTINS.has(w)) out += wrap("builtin", w);
        else if (/^(def|class)\s+$/.test(line.slice(0, i).match(/(def|class)\s+$/)?.[0] ?? ""))
          out += wrap("defname", w);
        else out += esc(w);
        i += w.length;
        continue;
      }

      const op = /^[+\-*/%=<>!&|^~@:,.[\]{}()]+/.exec(rest);
      if (op) {
        out += wrap("op", op[0]);
        i += op[0].length;
        continue;
      }

      out += esc(rest[0]);
      i += 1;
    }
    if (li < lines.length - 1) out += "\n";
  }
  // A trailing newline would otherwise not produce a final line box, leaving
  // the last line of the textarea uncoloured.
  return out + "\n";
}

export function gutter(source) {
  const n = source.split("\n").length;
  let out = "";
  for (let i = 1; i <= n; i++) out += `<div class="ln">${i}</div>`;
  return out;
}

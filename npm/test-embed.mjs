// Node check of petitpy/embed: node npm/test-embed.mjs <dir with the assembled package>
import { readFileSync } from "node:fs";
import { join } from "node:path";

const dir = process.argv[2];
const { loadInterpreter, PythonError, PyObject } = await import(join(dir, "embed.js"));
const out = [];
const py = await loadInterpreter({
  wasm: readFileSync(join(dir, "petitpy-embed.wasm")),
  path: ["/lib"],
  argv: ["app"],
  files: { "lib/helper.py": "X = 7\n" },
  onStdout: (line) => out.push(line),
});

let failed = false;
function check(name, fn, want) {
  let got;
  try {
    got = fn();
  } catch (e) {
    got = e;
  }
  const ok =
    JSON.stringify(got, (k, v) => (typeof v === "bigint" ? `${v}n` : v)) ===
    JSON.stringify(want, (k, v) => (typeof v === "bigint" ? `${v}n` : v));
  console.log(
    `${ok ? "PASS" : "FAIL"}  ${name}${ok ? "" : `  got ${got instanceof Error ? got.stack : JSON.stringify(got, (k, v) => (typeof v === "bigint" ? `${v}n` : v))}`}`,
  );
  failed ||= !ok;
}
function raises(fn) {
  try {
    fn();
    return "no error";
  } catch (e) {
    return e instanceof PythonError ? [e.type, e.message, e.exitCode ?? null] : String(e);
  }
}

check(
  "state survives between calls",
  () => (py.exec("def area(w, h):\n    return w * h\ncount = 0"), py.call("area", 6, 7)),
  42,
);
check("values to JS", () => py.eval("[None, True, 1.5, 'h\\u00e9', b'ab', (1, 2), {'k': [3]}]"), [
  null,
  true,
  1.5,
  "hé",
  { 0: 97, 1: 98 },
  [1, 2],
  { k: [3] },
]);
check("big ints", () => [py.eval("2**70"), py.eval("-(2**40)")], [
  1180591620717411303424n,
  -1099511627776,
]);
check(
  "values to Python",
  () => (
    py.set("v", { a: [1, null, "x"], b: 2n ** 80n, c: false }),
    py.eval("v['a'] == [1, None, 'x'] and v['b'] == 2**80 and v['c'] is False")
  ),
  true,
);
check("print reaches onStdout", () => (py.exec("print('hello', 6 * 7)"), out.at(-1)), "hello 42");
check(
  "import from files and frozen",
  () => py.eval("__import__('helper').X + len(__import__('json').dumps([1]))"),
  10,
);
check("sys.argv", () => py.eval("__import__('sys').argv"), ["app"]);
check("exception", () => raises(() => py.exec("raise ValueError('boom')")), [
  "ValueError",
  "ValueError: boom",
  null,
]);
check("SystemExit", () => raises(() => py.exec("raise SystemExit(4)")), [
  "SystemExit",
  "SystemExit: 4",
  4,
]);
check("C raise caught", () => raises(() => py.eval("(2**100) // 0")), [
  "ZeroDivisionError",
  "ZeroDivisionError: divide by zero",
  null,
]);

py.define("host", "twice", (n) => 2 * n);
py.define("host", "fail", () => {
  throw new TypeError("bad input");
});
py.define("host", "apply", (f, x) => f.call(x));
py.define("host", "keep", (o) => (globalThis.kept = o));
check("Python calls JS", () => (py.exec("import host"), py.eval("host.twice(21)")), 42);
check("JS error becomes Python's", () => raises(() => py.exec("host.fail()")), [
  "TypeError",
  "TypeError: bad input",
  null,
]);
check(
  "caught in Python",
  () => (py.exec("try:\n    host.fail()\nexcept TypeError as e:\n    msg = str(e)"), py.get("msg")),
  "bad input",
);
check(
  "nested: Python -> JS -> Python",
  () => py.eval("host.apply(lambda v: host.twice(v) + 1, 20)"),
  41,
);
check(
  "Python error through JS keeps its type",
  () => raises(() => py.eval("host.apply(lambda v: {}[v], 'k')")),
  ["KeyError", "KeyError: k", null],
);
check(
  "PyObject kept by JS",
  () => (
    py.exec(
      "class P:\n    def __init__(self): self.x = 5\nhost.keep(P())\nimport gc\ngc.collect()",
    ),
    py.exec("for i in range(5000): s = str(i) * 4"),
    [kept instanceof PyObject, kept.get("x")]
  ),
  [true, 5],
);
check("PyObject method call", () => py.import("json").get("dumps").call({ a: 1 }), '{"a": 1}');
check(
  "handles do not leak",
  () => {
    for (let i = 0; i < 20000; i++) py.call("area", i, 2);
    return py.call("area", 3, 3);
  },
  9,
);

py.free();
console.log(failed ? "FAILED" : "all passed");
process.exit(failed ? 1 : 0);

// Node check of the npm package: node npm/test.mjs <dir with the assembled package>
import { readFileSync } from "node:fs";
import { join } from "node:path";

const dir = process.argv[2];
const { loadPetitpy } = await import(join(dir, "index.js"));
const py = await loadPetitpy({ wasm: readFileSync(join(dir, "petitpy.wasm")) });

let failed = false;
function check(name, ok, detail) {
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}  ${detail}`);
  failed ||= !ok;
}

let r = await py.run('print("hello", 6 * 7, "h\\u00e9llo"[1:3])');
check("run prints", r.stdout === "hello 42 él\n" && r.exitCode === 0, JSON.stringify(r.stdout));

r = await py.run("import helper, sys\nprint(helper.X, input(), sys.argv[1:])", {
  files: { "lib/helper.py": "X = 7\n" },
  stdin: "typed\n",
  argv: ["a", "b"],
});
check("files, stdin, argv", r.stdout === "7 typed ['a', 'b']\n", JSON.stringify(r.stdout));

r = await py.run("raise ValueError('boom')");
check("error exit", r.exitCode === 1 && r.stderr.includes("ValueError: boom"), JSON.stringify(r.stderr));

// A raise inside MicroPython's C integer code, caught through wasm
// exception handling.
r = await py.run("try:\n    (2**100) // 0\nexcept ZeroDivisionError:\n    print('caught', 2**70)");
check("bignums, C raise caught", r.stdout === "caught 1180591620717411303424\n", JSON.stringify(r.stdout));

const lines = [];
r = await py.run("print('streamed')", { onStdout: (l) => lines.push(l) });
check("onStdout", lines.join() === "streamed", JSON.stringify(lines));

process.exit(failed ? 1 : 0);

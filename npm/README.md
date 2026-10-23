# petitpy

petitpy is a small Python runtime for the browser and Node: written in Zig, with direct DOM access from Python through the `js` module, building on MicroPython, whose `.mpy` bytecode it shares. The wasm is about 350 KB (about 170 KB gzipped).

```js
import { loadPetitpy } from "petitpy";

const py = await loadPetitpy();
const { stdout, stderr, exitCode } = await py.run('print("hello from", 6 * 7)');
```

`loadPetitpy()` compiles `petitpy.wasm` once; pass `{ wasm }` (a URL, a `Response`, bytes or a `WebAssembly.Module`) to load it from elsewhere. Each `run(source, options)` gets a fresh instance:

- `stdin`: text for `input()`.
- `files`: extra files by path; modules under `lib/` are importable.
- `argv`: `sys.argv[1:]`.
- `onStdout`, `onStderr`: called per printed line, also after `run()` returns, for programs that keep running through JS callbacks.

From Python, `import js` reaches the page: `js.document.getElementById("out").textContent = "hi"`.

## A long-lived interpreter (experimental)

`petitpy/embed` keeps one interpreter alive, so a page can define Python functions once and call them on every click, without running a whole program each time:

```js
import { loadInterpreter } from "petitpy/embed";

const py = await loadInterpreter();
py.define("host", "log", (msg) => console.log(msg));
py.exec("import host\ndef area(w, h):\n    host.log('computing')\n    return w * h");
py.call("area", 6, 7); // 42
py.eval("[1, 'two', None]"); // [1, "two", null]
```

`exec(source)` runs code in `__main__`, `eval(expr)` returns a value, `call(name, ...args)` calls a global, `get` and `set` read and write globals, and `define(module, name, fn)` makes a JS function callable from Python. `None`, `bool`, `int`, `float`, `str`, `bytes`, `list`, `tuple` and `dict` convert both ways (an `int` beyond 2\*\*53 is a `BigInt`); any other object comes back as a `PyObject` with `call`, `get`, `set` and `release`. A Python exception is thrown as a `PythonError` with its `type` and `traceback`; an error thrown by a JS function is raised in Python. `loadInterpreter({ path, argv, files, stdin, onStdout, onStderr })` configures it as `run()` does, except that modules under `files` are importable only from the directories in `path`, such as `"/lib"`. It loads its own wasm, `petitpy-embed.wasm`.

This is an alpha. The language is close to CPython (Unicode strings, `match`, floats, exception chaining) with MicroPython's limits: dicts are not insertion-ordered, `upper()`/`lower()` are ASCII-only. See the [differences from CPython](https://petitpy.lab.abilian.com/differences/) and the [playground](https://petitpy.lab.abilian.com/play/demos/playground/).

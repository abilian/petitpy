# petitpy

petitpy is a small Python runtime for the browser and Node (developed as nanopython): written in Zig, with direct DOM access from Python through the `js` module, building on MicroPython, whose `.mpy` bytecode it shares. The wasm is about 350 KB (about 170 KB gzipped).

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

This is an alpha. The language is close to CPython (Unicode strings, `match`, floats, exception chaining) with MicroPython's limits: no arbitrary-precision integers in the browser build, dicts are not insertion-ordered, `upper()`/`lower()` are ASCII-only. See the [differences from CPython](https://petitpy.lab.abilian.com/differences/) and the [playground](https://petitpy.lab.abilian.com/play/demos/playground/).

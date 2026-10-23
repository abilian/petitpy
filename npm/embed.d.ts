// Types for petitpy/embed: a long-lived Python interpreter.

/** A Python object with no JavaScript counterpart. */
export class PyObject {
  call(...args: unknown[]): unknown;
  get(name: string): unknown;
  set(name: string, value: unknown): void;
  repr(): string;
  /** Lets Python free the object now rather than when JavaScript collects this proxy. */
  release(): void;
}

/** A Python exception, or SystemExit (type "SystemExit", with exitCode). */
export class PythonError extends Error {
  type: string;
  traceback: string;
  exception: PyObject;
  exitCode?: number;
}

export interface Interpreter {
  /** Run source code in __main__. */
  exec(source: string, filename?: string): void;
  /** Evaluate an expression and return its value. */
  eval(source: string): unknown;
  /** Call a global of __main__, by name, or a PyObject. */
  call(fn: string | PyObject, ...args: unknown[]): unknown;
  get(name: string): unknown;
  set(name: string, value: unknown): void;
  import(name: string): PyObject;
  /** Make fn callable from Python as module.name; what it throws is raised in Python. */
  define(module: string, name: string, fn: (...args: any[]) => unknown): void;
  free(): void;
}

export interface InterpreterOptions {
  /** URL, Response, bytes or WebAssembly.Module (default: petitpy-embed.wasm next to this module). */
  wasm?: URL | string | Response | ArrayBuffer | ArrayBufferView | WebAssembly.Module;
  /** Directories of sys.path, such as "/lib". */
  path?: string[];
  argv?: string[];
  /** Files of the virtual filesystem, by path. */
  files?: Record<string, string | Uint8Array>;
  stdin?: string;
  onStdout?: (line: string) => void;
  onStderr?: (line: string) => void;
}

export function loadInterpreter(options?: InterpreterOptions): Promise<Interpreter>;

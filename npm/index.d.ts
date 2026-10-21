export interface RunOptions {
  /** Text read by input() and sys.stdin. */
  stdin?: string;
  /** Extra files, by path; put importable modules under "lib/". */
  files?: Record<string, string | Uint8Array>;
  /** Arguments after the script name (sys.argv[1:]). */
  argv?: string[];
  /** Called with each line printed to stdout, including after run() returns. */
  onStdout?: (line: string) => void;
  /** Called with each line printed to stderr. */
  onStderr?: (line: string) => void;
}

export interface RunResult {
  stdout: string;
  stderr: string;
  exitCode: number;
  /** The live instance, for programs that keep running through JS callbacks. */
  instance: WebAssembly.Instance;
}

export interface Petitpy {
  module: WebAssembly.Module;
  run(source: string, options?: RunOptions): Promise<RunResult>;
}

/** Compile petitpy.wasm once (default: the file shipped next to this module). */
export function loadPetitpy(options?: {
  wasm?: URL | string | Response | ArrayBuffer | ArrayBufferView | WebAssembly.Module;
}): Promise<Petitpy>;

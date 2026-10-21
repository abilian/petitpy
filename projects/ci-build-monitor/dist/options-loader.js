// options.html entry-point: boot wasm + run /src/pages_options.py.
import { bootstrap } from "./bootstrap.js";

bootstrap("/src/pages_options.py").catch(console.error);

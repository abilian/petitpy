// status.html entry-point: boot wasm + run /src/pages_status.py.
import { bootstrap } from "./bootstrap.js";

bootstrap("/src/pages_status.py").catch(console.error);

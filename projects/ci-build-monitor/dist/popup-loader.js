// popup.html entry-point: boot wasm + run /src/pages_popup.py.
import { bootstrap } from "./bootstrap.js";

bootstrap("/src/pages_popup.py").catch(console.error);

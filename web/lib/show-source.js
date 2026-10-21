// Lists a demo's own source under the demo, so the page doubles as a
// tutorial. The page holds `<section class="source" data-files="main.py">`;
// each named file is fetched next to the page and shown, Python highlighted.
import { highlight } from "./highlight.js";

const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

for (const section of document.querySelectorAll("section.source[data-files]")) {
  section.innerHTML = "<h2>Source</h2>";
  for (const name of section.dataset.files.split(/\s+/)) {
    const text = await (await fetch(`./${name}`, { cache: "no-store" })).text();
    const body = name.endsWith(".py") ? highlight(text) : esc(text);
    section.insertAdjacentHTML(
      "beforeend",
      `<details open><summary><code>${name}</code> (<a href="./${name}">raw</a>)</summary><pre>${body}</pre></details>`,
    );
  }
}

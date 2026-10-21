// The browser WASI shim keys a directory's entries by name, so "lib/x.py"
// needs a "lib" Directory holding "x.py"; a flat "lib/x.py" key is never
// found. `Directory` is the shim's class, passed in so this module works
// with the shim from a CDN (the pages) or from npm (the package).
export function addFile(root, path, file, Directory) {
  const parts = path.split("/").filter(Boolean);
  let dir = root;
  for (const name of parts.slice(0, -1)) {
    let sub = dir.get(name);
    if (!(sub instanceof Directory)) {
      sub = new Directory(new Map());
      dir.set(name, sub);
    }
    dir = sub.contents;
  }
  dir.set(parts[parts.length - 1], file);
}

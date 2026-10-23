// zpip-browser.js — browser-side mip-compatible package fetcher + IndexedDB cache.
//
// ADR-003 L4. Mirrors tools/zpip.py's wire protocol against
// `micropython.org/pi/v2`, but stores fetched files in IndexedDB (object
// store `packages`) instead of the filesystem. Used by app.js to mount
// requested packages into the WASI PreopenDirectory at `/lib/<pkg>/...`
// before each Run.
//
// Cache key (per ADR-003 D6/D7):
//   petitpy:<runtime>:<package>@<version>
// LRU eviction at 10 MB total cap.

const REGISTRY = "https://micropython.org/pi/v2";
const MPY_VERSION = "py"; // .py source — wasm reads them via the L1 filesystem importer
const RUNTIME = "0.x.x"; // ADR-003 D7 example key prefix; bump when binary ABI shifts
const DB_NAME = "petitpy-cache";
const DB_VERSION = 1;
const STORE = "packages";
const CAP_BYTES = 10 * 1024 * 1024; // 10 MB

// ---- IndexedDB plumbing -----------------------------------------------------

function _open() {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, DB_VERSION);
    req.onupgradeneeded = () => {
      const db = req.result;
      if (!db.objectStoreNames.contains(STORE)) {
        // keyPath = "key" — we store full records { key, package, version, files, bytes, atime }
        db.createObjectStore(STORE, { keyPath: "key" });
      }
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

function _req(req) {
  return new Promise((resolve, reject) => {
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

// Resolves when `tx` commits. Created with the transaction: a transaction
// with no pending requests commits on its own, so an `oncomplete` handler
// assigned after the last awaited request can miss the event and hang.
function _done(tx) {
  return new Promise((resolve, reject) => {
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
    tx.onabort = () => reject(tx.error);
  });
}

function _cacheKey(pkg, version) {
  return `petitpy:${RUNTIME}:${pkg}@${version}`;
}

export async function openCache() {
  return _open();
}

export async function getCached(pkg, version) {
  const db = await _open();
  const key = _cacheKey(pkg, version);
  const tx = db.transaction(STORE, "readwrite");
  const done = _done(tx);
  const store = tx.objectStore(STORE);
  const rec = await _req(store.get(key));
  if (!rec) {
    db.close();
    return null;
  }
  rec.atime = Date.now();
  await _req(store.put(rec));
  await done;
  db.close();
  return rec.files;
}

export async function setCached(pkg, version, files) {
  const db = await _open();
  const key = _cacheKey(pkg, version);
  const bytes = files.reduce((n, f) => n + (f.content?.byteLength ?? 0), 0);
  const rec = {
    key,
    package: pkg,
    version,
    files,
    bytes,
    atime: Date.now(),
  };

  // Evict LRU until under cap. The cap is enforced AFTER inserting the new
  // record so an oversized single package can still land; total stays bounded.
  const tx = db.transaction(STORE, "readwrite");
  const done = _done(tx);
  const store = tx.objectStore(STORE);
  await _req(store.put(rec));

  const all = await _req(store.getAll());
  let total = all.reduce((n, r) => n + (r.bytes ?? 0), 0);
  if (total > CAP_BYTES) {
    const sorted = all
      .filter((r) => r.key !== key) // never evict the record we just inserted
      .sort((a, b) => (a.atime ?? 0) - (b.atime ?? 0));
    for (const victim of sorted) {
      if (total <= CAP_BYTES) break;
      await _req(store.delete(victim.key));
      total -= victim.bytes ?? 0;
    }
  }
  await done;
  db.close();
}

export async function deleteCached(pkg) {
  const db = await _open();
  const tx = db.transaction(STORE, "readwrite");
  const done = _done(tx);
  const store = tx.objectStore(STORE);
  const all = await _req(store.getAll());
  for (const rec of all) {
    if (rec.package === pkg) {
      await _req(store.delete(rec.key));
    }
  }
  await done;
  db.close();
}

export async function clearCache() {
  const db = await _open();
  const tx = db.transaction(STORE, "readwrite");
  const done = _done(tx);
  const store = tx.objectStore(STORE);
  await _req(store.clear());
  await done;
  db.close();
}

export async function listCached() {
  const db = await _open();
  const tx = db.transaction(STORE, "readonly");
  const store = tx.objectStore(STORE);
  const all = await _req(store.getAll());
  db.close();
  return all.map((r) => ({
    package: r.package,
    version: r.version,
    bytes: r.bytes,
    atime: r.atime,
  }));
}

// ---- Registry fetch ---------------------------------------------------------

let _indexCache = null;

async function _fetchIndex() {
  if (_indexCache) return _indexCache;
  const resp = await fetch(`${REGISTRY}/index.json`);
  if (!resp.ok) throw new Error(`index.json HTTP ${resp.status}`);
  _indexCache = await resp.json();
  return _indexCache;
}

async function _fetchBytes(url) {
  const resp = await fetch(url);
  if (!resp.ok) throw new Error(`${url} HTTP ${resp.status}`);
  const buf = await resp.arrayBuffer();
  return new Uint8Array(buf);
}

// Fetches package metadata + files. Mirrors zpip.py's _install_package_json
// and _install_named: GET package/<mpy>/<name>/<version>.json, follow
// `hashes` to file/<hh>/<hash>, recurse into `deps`. The result is a flat
// array of { name, content } where name is the on-disk path the package
// declares (e.g. "abc.py" or "urllib/parse.py").
async function _fetchPackageInternal(name, version, visited, files) {
  const url = `${REGISTRY}/package/${MPY_VERSION}/${name}/${version}.json`;
  if (visited.has(url)) return;
  visited.add(url);

  const metaResp = await fetch(url);
  if (!metaResp.ok) throw new Error(`${name}@${version}: HTTP ${metaResp.status}`);
  const meta = await metaResp.json();

  for (const [targetPath, shortHash] of meta.hashes ?? []) {
    const fileUrl = `${REGISTRY}/file/${shortHash.slice(0, 2)}/${shortHash}`;
    const content = await _fetchBytes(fileUrl);
    files.push({ name: targetPath, content });
  }
  for (const [targetPath, fileUrl] of meta.urls ?? []) {
    const content = await _fetchBytes(fileUrl);
    files.push({ name: targetPath, content });
  }
  for (const [depName, depVersion] of meta.deps ?? []) {
    await _fetchPackageInternal(depName, depVersion || "latest", visited, files);
  }
}

// Public entry point. Returns [{name, content}] ready to mount.
// Cache hit: returns the cached array (also updates atime).
// Cache miss: fetches, caches, returns.
export async function fetchPackage(name, options = {}) {
  const version = options.version || "latest";

  const cached = await getCached(name, version);
  if (cached) return cached;

  const idx = await _fetchIndex();
  const entry = (idx.packages ?? []).find((p) => p.name === name);
  // resolvedVersion is what we'll key the cache under. For "latest" we resolve
  // to the registry's reported version so a future re-fetch hits even if
  // upstream rolls "latest" to a new SHA.
  let resolvedVersion = version;
  if (version === "latest") {
    resolvedVersion = entry?.version ?? "latest";
  }

  // If the user already has resolvedVersion cached, return that (handles the
  // case where they ask for "latest" twice and we resolve to the same version).
  if (resolvedVersion !== version) {
    const cached2 = await getCached(name, resolvedVersion);
    if (cached2) return cached2;
  }

  const files = [];
  const visited = new Set();
  await _fetchPackageInternal(name, version, visited, files);

  await setCached(name, resolvedVersion, files);
  return files;
}

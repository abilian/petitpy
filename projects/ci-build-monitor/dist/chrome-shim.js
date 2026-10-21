// chrome.* polyfill for running ci-build-monitor pages in a plain browser
// tab (no extension context). Loaded as a classic <script> BEFORE the
// module loader so window.chrome is in place when the wasm bootstraps.
//
// Stubs: chrome.storage.local (localStorage-backed), chrome.notifications
// (console-logged), chrome.alarms (setInterval-backed), chrome.runtime
// (openOptionsPage + no-op message channel). Returns early if a real
// chrome.storage is already present (i.e. real extension context).
(function () {
  if (typeof window === "undefined") return;
  if (window.chrome && window.chrome.storage) return;

  var STORAGE_KEY = "ci-build-monitor-storage";

  function readAll() {
    try {
      var raw = window.localStorage.getItem(STORAGE_KEY);
      if (!raw) return {};
      var parsed = JSON.parse(raw);
      return parsed && typeof parsed === "object" ? parsed : {};
    } catch (e) {
      return {};
    }
  }

  function writeAll(data) {
    try {
      window.localStorage.setItem(STORAGE_KEY, JSON.stringify(data));
    } catch (e) {
      // quota / disabled storage — silently ignore in the shim
    }
  }

  function pickKeys(all, keys) {
    var out = {};
    if (keys === null || keys === undefined) {
      // chrome.storage convention: null/undefined returns everything
      for (var k in all) {
        if (Object.prototype.hasOwnProperty.call(all, k)) out[k] = all[k];
      }
      return out;
    }
    if (typeof keys === "string") {
      if (Object.prototype.hasOwnProperty.call(all, keys)) out[keys] = all[keys];
      return out;
    }
    if (Array.isArray(keys)) {
      for (var i = 0; i < keys.length; i++) {
        var key = keys[i];
        if (Object.prototype.hasOwnProperty.call(all, key)) out[key] = all[key];
      }
      return out;
    }
    if (typeof keys === "object") {
      // dict of default values
      for (var dk in keys) {
        if (Object.prototype.hasOwnProperty.call(keys, dk)) {
          out[dk] = Object.prototype.hasOwnProperty.call(all, dk) ? all[dk] : keys[dk];
        }
      }
      return out;
    }
    return out;
  }

  var storageLocal = {
    get: function (keys, cb) {
      var result = pickKeys(readAll(), keys);
      if (typeof cb === "function") {
        cb(result);
        return undefined;
      }
      return Promise.resolve(result);
    },
    set: function (items, cb) {
      var all = readAll();
      if (items && typeof items === "object") {
        for (var k in items) {
          if (Object.prototype.hasOwnProperty.call(items, k)) all[k] = items[k];
        }
      }
      writeAll(all);
      if (typeof cb === "function") {
        cb();
        return undefined;
      }
      return Promise.resolve();
    },
    remove: function (keys, cb) {
      var all = readAll();
      var list = Array.isArray(keys) ? keys : [keys];
      for (var i = 0; i < list.length; i++) {
        delete all[list[i]];
      }
      writeAll(all);
      if (typeof cb === "function") {
        cb();
        return undefined;
      }
      return Promise.resolve();
    },
    clear: function (cb) {
      writeAll({});
      if (typeof cb === "function") {
        cb();
        return undefined;
      }
      return Promise.resolve();
    },
  };

  var notifications = {
    create: function (id, opts, cb) {
      console.log("[chrome-shim] notifications.create", id, opts);
      if (typeof cb === "function") {
        cb(id);
        return undefined;
      }
      return Promise.resolve(id);
    },
    clear: function (id, cb) {
      console.log("[chrome-shim] notifications.clear", id);
      if (typeof cb === "function") {
        cb(true);
        return undefined;
      }
      return Promise.resolve(true);
    },
    onClicked: {
      addListener: function (_fn) {
        // accept but ignore — shim has no real notification UI to click
      },
    },
  };

  var alarmIntervals = {}; // name -> intervalId
  var alarmListeners = [];
  var alarms = {
    create: function (name, opts) {
      if (alarmIntervals[name]) {
        window.clearInterval(alarmIntervals[name]);
        delete alarmIntervals[name];
      }
      var minutes = opts && opts.periodInMinutes ? opts.periodInMinutes : 1;
      var ms = minutes * 60 * 1000;
      alarmIntervals[name] = window.setInterval(function () {
        for (var i = 0; i < alarmListeners.length; i++) {
          try {
            alarmListeners[i]({ name: name });
          } catch (e) {
            console.warn("[chrome-shim] alarm listener threw", e);
          }
        }
      }, ms);
      console.log("[chrome-shim] alarms.create", name, "every", ms, "ms");
    },
    clear: function (name, cb) {
      if (alarmIntervals[name]) {
        window.clearInterval(alarmIntervals[name]);
        delete alarmIntervals[name];
      }
      if (typeof cb === "function") {
        cb(true);
        return undefined;
      }
      return Promise.resolve(true);
    },
    onAlarm: {
      addListener: function (fn) {
        alarmListeners.push(fn);
      },
    },
  };

  var tabs = {
    create: function (opts, cb) {
      var url = opts && opts.url ? opts.url : null;
      if (url) {
        // In standalone-web (no extension context) there are no real
        // browser tabs to spawn; navigate the current window instead so
        // the user-visible behaviour matches "open dashboard".
        window.location.href = url;
      }
      if (typeof cb === "function") {
        cb({ id: 0, url: url });
        return undefined;
      }
      return Promise.resolve({ id: 0, url: url });
    },
  };

  var runtime = {
    openOptionsPage: function (cb) {
      window.location.href = "options.html";
      if (typeof cb === "function") cb();
      return Promise.resolve();
    },
    sendMessage: function (_msg, cb) {
      if (typeof cb === "function") cb(undefined);
      return Promise.resolve(undefined);
    },
    onMessage: {
      addListener: function (_fn) {
        // no-op: no extension messaging in standalone web context
      },
    },
  };

  window.chrome = window.chrome || {};
  window.chrome.storage = { local: storageLocal };
  window.chrome.notifications = notifications;
  window.chrome.alarms = alarms;
  window.chrome.runtime = runtime;
  window.chrome.tabs = tabs;

  console.log("[chrome-shim] installed standalone-web stubs");
})();

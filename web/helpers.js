/* Small browser adapter used by the Haskell WebAssembly module.
 * All application decisions are made in app/Main.hs; this file only touches
 * the DOM, IndexedDB and a few date helpers.  No network calls happen here.
 */
(function () {
  "use strict";

  let db = null;

  const pad = (n) => String(n).padStart(2, "0");
  const esc = (s) =>
    String(s).replace(/[&<>"']/g, (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]
    );

  function dateOf(ms) {
    const d = new Date(ms);
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
  }

  function timeOf(ms) {
    const d = new Date(ms);
    return `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
  }

  function hhmm(ms) {
    const d = new Date(ms);
    return `${pad(d.getHours())}:${pad(d.getMinutes())}`;
  }

  function parts(day) {
    const [y, m, d] = String(day).split("-").map(Number);
    return [y, m, d];
  }

  const TT = {
    /* ---- time ---------------------------------------------------------- */
    now: () => Date.now(),
    uuid: () =>
      globalThis.crypto?.randomUUID
        ? globalThis.crypto.randomUUID()
        : `id-${Date.now()}-${Math.random().toString(36).slice(2)}`,
    today: () => dateOf(Date.now()),
    dateOf,
    timeOf,
    hhmm,
    shiftDay: (day, n) => {
      const [y, m, d] = parts(day);
      const dt = new Date(y, m - 1, d);
      dt.setDate(dt.getDate() + n);
      return dateOf(dt.getTime());
    },
    parseTime: (day, value) => {
      const [y, m, d] = parts(day);
      const [h, min] = String(value).split(":").map(Number);
      return new Date(y, m - 1, d, h || 0, min || 0, 0, 0).getTime();
    },

    /* ---- DOM ----------------------------------------------------------- */
    el: (id) => document.getElementById(id),
    setText: (id, value) => {
      const el = document.getElementById(id);
      if (el) el.textContent = value;
    },
    clear: (id) => {
      const el = document.getElementById(id);
      if (el) el.replaceChildren();
    },
    show: (id, on) => {
      const el = document.getElementById(id);
      if (el) el.classList.toggle("hidden", !on);
    },
    active: (id, on) => {
      const el = document.getElementById(id);
      if (el) el.classList.toggle("active", Boolean(on));
    },
    getValue: (id) => document.getElementById(id)?.value ?? "",
    setValue: (id, value) => {
      const el = document.getElementById(id);
      if (el) el.value = value;
    },
    append: (id, node) => document.getElementById(id)?.appendChild(node),
    appendTo: (parent, node) => parent?.appendChild(node),
    keyRow: () => {
      const row = document.createElement("div");
      row.className = "kb-row";
      return row;
    },
    tile: (glyph, label, action, payload, extra) => {
      const b = document.createElement("button");
      b.type = "button";
      b.className = `tile ${extra || ""}`.trim();
      b.dataset.action = action;
      if (payload) b.dataset.value = payload;
      b.innerHTML =
        `<span class="glyph">${esc(glyph)}</span>` +
        `<span class="tile-label">${esc(label)}</span>`;
      return b;
    },
    row: (id, clock, glyph, label, duration, editing) => {
      const wrap = document.createElement("div");
      wrap.className = `entry${editing ? " editing" : ""}`;

      const main = document.createElement("button");
      main.type = "button";
      main.className = "entry-main";
      main.dataset.action = "edit";
      main.dataset.value = id;
      main.innerHTML =
        `<span class="entry-time">${esc(clock)}</span>` +
        `<span class="entry-glyph">${esc(glyph)}</span>` +
        `<span class="entry-text"><strong>${esc(label)}</strong>` +
        `<small>${esc(duration)}</small></span>`;

      const del = document.createElement("button");
      del.type = "button";
      del.className = "entry-del";
      del.dataset.action = "delete";
      del.dataset.value = id;
      del.setAttribute("aria-label", "Delete entry");
      del.textContent = "🗑";

      wrap.append(main, del);
      return wrap;
    },
    vibrate: () => {
      try { globalThis.navigator?.vibrate?.(25); } catch (_) { /* ignore */ }
    },
    confirm: (message) => globalThis.confirm(message),
    download: (name, text) => {
      const url = URL.createObjectURL(
        new Blob([text], { type: "text/csv;charset=utf-8" })
      );
      const a = document.createElement("a");
      a.href = url;
      a.download = name;
      document.body.appendChild(a);
      a.click();
      a.remove();
      setTimeout(() => URL.revokeObjectURL(url), 1000);
    },
    log: (message) => console.log("[time-tracking]", message),

    /* ---- storage (all local, nothing leaves the device) ---------------- */
    idbOpen: () => new Promise((resolve, reject) => {
      if (!globalThis.indexedDB) {
        reject(new Error("IndexedDB is not available in this browser"));
        return;
      }
      const req = indexedDB.open("time-tracking", 1);
      req.onupgradeneeded = () => {
        const database = req.result;
        if (!database.objectStoreNames.contains("entries")) {
          const store = database.createObjectStore("entries", { keyPath: "id" });
          store.createIndex("byTs", "ts");
        }
      };
      req.onsuccess = () => {
        db = req.result;
        db.onversionchange = () => { db.close(); db = null; };
        resolve(true);
      };
      req.onerror = () => reject(req.error || new Error("Could not open IndexedDB"));
    }),

    idbAll: () => new Promise((resolve, reject) => {
      if (!db) { reject(new Error("Database not open")); return; }
      const tx = db.transaction("entries", "readonly");
      const req = tx.objectStore("entries").getAll();
      req.onsuccess = () => resolve(
        req.result.map((r) => ({
          id: r.id,
          icon: r.icon,
          ts: r.ts,
          label: r.label,
          date: r.date || dateOf(r.ts)
        }))
      );
      req.onerror = () => reject(req.error);
    }),

    idbPut: (id, icon, ts, label) => new Promise((resolve, reject) => {
      if (!db) { reject(new Error("Database not open")); return; }
      const tx = db.transaction("entries", "readwrite");
      tx.objectStore("entries").put({
        id, icon, ts, label, date: dateOf(ts)
      });
      tx.oncomplete = () => resolve(true);
      tx.onerror = () => reject(tx.error);
    }),

    idbDelete: (id) => new Promise((resolve, reject) => {
      if (!db) { reject(new Error("Database not open")); return; }
      const tx = db.transaction("entries", "readwrite");
      tx.objectStore("entries").delete(id);
      tx.oncomplete = () => resolve(true);
      tx.onerror = () => reject(tx.error);
    })
  };

  globalThis.TT = TT;
})();

/* Headless smoke test: runs the real compiled Haskell module in Node with a
 * tiny in-memory stand-in for the browser APIs used through JSFFI. */
import assert from "node:assert/strict";
import fs from "node:fs";
import { WASI } from "../web/vendor/wasi.js";
import ghcWasmJsffi from "../web/dist/time-tracking.js";

const store = [];
const texts = {};
const values = {};
const classes = {};
const children = {};
let clock = Date.UTC(2026, 10, 23, 9, 0, 0);
let ids = 0;
let confirmed = true;
const downloads = [];

const pad = (n) => String(n).padStart(2, "0");
const dateOf = (ms) => {
  const d = new Date(ms);
  return `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}`;
};
const timeOf = (ms) => {
  const d = new Date(ms);
  return `${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}:${pad(d.getUTCSeconds())}`;
};

globalThis.TT = {
  now: () => (clock += 60_000),
  uuid: () => `id-${++ids}`,
  today: () => dateOf(clock),
  dateOf, timeOf,
  hhmm: (ms) => timeOf(ms).slice(0, 5),
  shiftDay: (day, n) => {
    const d = new Date(`${day}T00:00:00Z`);
    d.setUTCDate(d.getUTCDate() + n);
    return dateOf(d.getTime());
  },
  parseTime: (day, hhmm) => {
    const [h, m] = hhmm.split(":").map(Number);
    const d = new Date(`${day}T00:00:00Z`);
    d.setUTCHours(h, m, 0, 0);
    return d.getTime();
  },
  setText: (id, s) => { texts[id] = s; },
  clear: (id) => { children[id] = []; },
  show: (id, on) => { classes[id] = { hidden: !on }; },
  active: (id, on) => { classes[id] = { active: !!on }; },
  getValue: (id) => values[id] ?? "",
  setValue: (id, v) => { values[id] = v; },
  append: (id, node) => { (children[id] ||= []).push(node); },
  appendTo: (parent, node) => { (parent.children ||= []).push(node); },
  keyRow: () => ({ children: [], kind: "row" }),
  tile: (glyph, label, action, payload, extra) =>
    ({ glyph, label, action, payload, extra, kind: "tile" }),
  row: (id, clockText, glyph, label, duration, editing) =>
    ({ id, clockText, glyph, label, duration, editing, kind: "row" }),
  vibrate: () => {},
  confirm: () => confirmed,
  download: (name, text) => { downloads.push({ name, text }); },
  log: () => {},
  idbOpen: async () => true,
  idbAll: async () => store.map((r) => ({ ...r })),
  idbPut: async (id, icon, ts, label) => {
    const existing = store.findIndex((r) => r.id === id);
    const record = { id, icon, ts, label, date: dateOf(ts) };
    if (existing >= 0) store[existing] = record; else store.push(record);
    return true;
  },
  idbDelete: async (id) => {
    const i = store.findIndex((r) => r.id === id);
    if (i >= 0) store.splice(i, 1);
    return true;
  }
};

const wasi = new WASI({ stdout: () => {}, stderr: () => {} });
const exportsRef = {};
const importObject = Object.assign(
  { ghc_wasm_jsffi: ghcWasmJsffi(exportsRef) },
  wasi.getImportObject()
);
const wasmBytes = fs.readFileSync(new URL("../web/dist/time-tracking.wasm", import.meta.url));
const result = await WebAssembly.instantiate(
  wasmBytes,
  importObject
);
Object.assign(exportsRef, result.instance.exports);
wasi.initialize(result);

const { start, onAction } = result.instance.exports;
await start();

assert.equal(texts["selected-day"], "2026-11-23");
assert.equal(children["icon-grid"].length, 17, "16 icons plus the type button");
assert.equal(children["icon-grid"][0].payload, "water");
assert.equal(children["icon-grid"][16].action, "type");

// Tap two icons: each must create a timestamped entry.
await onAction("icon", "water");
await onAction("icon", "code");
assert.equal(store.length, 2);
assert.equal(store[0].icon, "water");
assert.equal(store[1].icon, "code");
assert.equal(store[1].date, "2026-11-23");
assert.match(texts["last-logged"], /Coding logged at/);

// Use the virtual keyboard for a precise label.
await onAction("type", "");
for (const ch of "standup") await onAction("key", ch);
await onAction("save", "");
assert.equal(store.length, 3);
assert.equal(store[2].label, "standup");
assert.equal(store[2].icon, "custom");

// Day view lists the entries and lets us edit one.
await onAction("screen", "day");
assert.equal(children["entry-list"].length, 3);
assert.equal(texts["day-count"], "3 entries");
await onAction("edit", store[2].id);
assert.equal(values["edit-time"], "09:03");
await onAction("key", "backspace");
await onAction("save", "");
assert.equal(store[2].label, "standu");

// Change its time and verify the entry moves to a different day if needed.
await onAction("edit", store[2].id);
values["edit-time"] = "23:30";
await onAction("save", "");
assert.equal(timeOf(store[2].ts).slice(0, 5), "23:30");

// Deletion and export.
await onAction("delete", store[0].id);
assert.equal(store.length, 2);
await onAction("export", "");
assert.equal(downloads.length, 1);
assert.match(downloads[0].text, /standu/);

console.log("Node smoke test passed:", store.length, "entries remain");

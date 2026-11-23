/* Browser integration test. Requires a Chromium binary in CHROMIUM and
 * playwright-core on NODE_PATH (both provided by the ghc-wasm dev shell).
 *
 *   CHROMIUM=$(command -v chromium) nix develop --command node scripts/test-browser.mjs
 */
import assert from "node:assert/strict";
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const { chromium } = require("playwright-core");

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "web");
const types = {
  ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript",
  ".css": "text/css", ".wasm": "application/wasm", ".json": "application/json",
  ".webmanifest": "application/manifest+json", ".png": "image/png"
};

const server = http.createServer((req, res) => {
  const rel = decodeURIComponent(new URL(req.url, "http://x").pathname);
  const file = path.join(root, rel === "/" ? "index.html" : rel);
  if (!file.startsWith(root) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) {
    res.writeHead(404).end("not found");
    return;
  }
  res.writeHead(200, { "content-type": types[path.extname(file)] || "application/octet-stream" });
  fs.createReadStream(file).pipe(res);
});

await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const url = `http://127.0.0.1:${server.address().port}/`;
const errors = [];

const browser = await chromium.launch({
  executablePath: process.env.CHROMIUM,
  args: ["--no-sandbox"]
});
try {
  const context = await browser.newContext();
  const page = await context.newPage();
  page.on("pageerror", (e) => errors.push(String(e)));
  page.on("console", (m) => { if (m.type() === "error") errors.push(m.text()); });

  await page.goto(url);
  await page.waitForFunction(
    () => document.getElementById("boot-screen")?.classList.contains("hidden"),
    null, { timeout: 60_000 }
  );

  assert.equal(await page.locator("#icon-grid .tile").count(), 17);
  await page.locator('[data-action="icon"][data-value="eat"]').click();
  await page.waitForFunction(
    () => document.getElementById("last-logged").textContent.includes("logged at")
  );

  await page.locator('[data-action="type"]').click();
  await page.locator("#kb-text").fill("team sync");
  await page.locator("#kb-save").click();

  const count = () => page.evaluate(() => new Promise((resolve, reject) => {
    const req = indexedDB.open("time-tracking");
    req.onsuccess = () => {
      const all = req.result.transaction("entries").objectStore("entries").getAll();
      all.onsuccess = () => resolve(all.result.length);
      all.onerror = () => reject(all.error);
    };
    req.onerror = () => reject(req.error);
  }));
  assert.equal(await count(), 2);

  await page.locator("#nav-day").click();
  assert.equal(await page.locator("#entry-list .entry").count(), 2);
  assert.match(await page.locator("#entry-list").textContent(), /team sync/);

  // Edit the note and its time.
  await page.locator('#entry-list [data-action="edit"][data-value^="id-"], #entry-list [data-action="edit"]').first().click();
  assert.equal(await page.locator("#kb-text").inputValue(), "team sync");
  await page.locator("#kb-text").fill("team sync edited");
  await page.locator("#edit-time").fill("12:34");
  await page.locator("#kb-save").click();
  const dayText = await page.locator("#entry-list").textContent();
  assert.match(dayText, /12:34/);
  assert.match(dayText, /team sync edited/);

  // The service worker should make a reload work with the network switched off.
  await page.evaluate(() => navigator.serviceWorker.ready);
  await page.waitForFunction(() => Boolean(navigator.serviceWorker.controller));
  await context.setOffline(true);
  await page.reload();
  await page.waitForFunction(
    () => document.getElementById("boot-screen")?.classList.contains("hidden"),
    null, { timeout: 60_000 }
  );
  await page.locator("#nav-day").click();
  assert.equal(await page.locator("#entry-list .entry").count(), 2);

  assert.deepEqual(errors, [], `browser errors: ${errors.join("\n")}`);
  console.log("Browser integration test passed (including offline reload)");
} finally {
  await browser.close();
  server.close();
}

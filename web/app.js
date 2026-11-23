import { WASI } from "./vendor/wasi.js";
import ghcWasmJsffi from "./dist/time-tracking.js";

async function boot() {
  const status = (msg) => globalThis.TT.setText("boot-status", msg);

  try {
    status("Loading Haskell runtime…");
    const wasi = new WASI({
      stdout: (s) => globalThis.TT.log(s),
      stderr: (s) => console.error("[time-tracking wasm]", s)
    });

    // The generated JSFFI glue needs the wasm exports, which only exist after
    // instantiation.  Mutation of this object ties that knot.
    const exportsRef = {};
    const jsffiImports = ghcWasmJsffi(exportsRef);
    const importObject = Object.assign(
      { ghc_wasm_jsffi: jsffiImports },
      wasi.getImportObject()
    );

    status("Starting application…");
    const response = fetch(new URL("./dist/time-tracking.wasm", import.meta.url));
    const result = await WebAssembly.instantiateStreaming(response, importObject);
    const exports = result.instance.exports;
    Object.assign(exportsRef, exports);

    // A WASI reactor must be initialised exactly once before calling exports.
    wasi.initialize(result);
    globalThis.__ttExports = exports;

    document.addEventListener("click", (ev) => {
      const el = ev.target.closest("[data-action]");
      if (!el) return;
      ev.preventDefault();
      const action = el.dataset.action;
      const value = el.dataset.value || "";
      Promise.resolve(exports.onAction(action, value)).catch((err) =>
        globalThis.TT.setText("app-status", `Error: ${err}`)
      );
    });

    // The on-screen keyboard is primary, but a hardware keyboard also works.
    document.addEventListener("keydown", (ev) => {
      const overlay = document.getElementById("keyboard-overlay");
      if (!overlay || overlay.classList.contains("hidden")) return;
      if (document.activeElement?.id === "edit-time") return;
      let key = null;
      if (ev.key === "Backspace") key = "backspace";
      else if (ev.key === "Enter") key = "enter";
      else if (ev.key === " ") key = "space";
      else if (ev.key.length === 1) key = ev.key;
      if (key === null) return;
      ev.preventDefault();
      Promise.resolve(exports.onAction("key", key)).catch(console.error);
    });

    await exports.start();
    document.getElementById("boot-screen").classList.add("hidden");
  } catch (err) {
    console.error(err);
    status(`Failed to start: ${err.message}`);
  }
}

boot();

if ("serviceWorker" in navigator) {
  navigator.serviceWorker
    .register(new URL("./sw.js", import.meta.url))
    .catch((err) => console.warn("Service worker registration failed", err));
}

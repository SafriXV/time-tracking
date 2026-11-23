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
    // Fetch as bytes rather than instantiateStreaming: Android WebView's
    // asset loader does not always send application/wasm for .wasm files.
    const response = await fetch(new URL("./dist/time-tracking.wasm", import.meta.url));
    if (!response.ok) throw new Error(`Could not load wasm (${response.status})`);
    const bytes = await response.arrayBuffer();
    const result = await WebAssembly.instantiate(bytes, importObject);
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

      // Show and focus the field inside the click gesture so Android opens
      // its native keyboard. The Haskell render will fill in the initial text.
      if (action === "type" || action === "edit") {
        document.getElementById("keyboard-overlay").classList.remove("hidden");
        document.getElementById("kb-text").focus();
        globalThis.TimeTrackerNative?.showKeyboard?.();
      }
      if (action === "cancel") {
        document.getElementById("kb-text").blur();
        globalThis.TimeTrackerNative?.hideKeyboard?.();
      }

      Promise.resolve(exports.onAction(action, value)).catch((err) =>
        globalThis.TT.setText("app-status", `Error: ${err}`)
      );
    });

    // Enter on the native keyboard submits the dialog.
    document.getElementById("kb-form").addEventListener("submit", (ev) => {
      ev.preventDefault();
      document.getElementById("kb-text").blur();
      globalThis.TimeTrackerNative?.hideKeyboard?.();
      Promise.resolve(exports.onAction("save", "")).catch((err) =>
        globalThis.TT.setText("app-status", `Error: ${err}`)
      );
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

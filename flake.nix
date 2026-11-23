{
  description = "Offline-first Haskell time tracker (browser/WebAssembly)";

  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    ghc-wasm.url = "github:haskell-wasm/ghc-wasm-meta";
  };

  outputs = { self, flake-utils, ghc-wasm }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        wasmTools = ghc-wasm.packages.${system}.default;
        pkgs = import ghc-wasm.inputs.nixpkgs { inherit system; };
        npmDeps = ghc-wasm.packages.${system}.npm-deps;
      in
      {
        devShells.default = pkgs.mkShell {
          packages = [ wasmTools ];
          shellHook = ''
            echo "Haskell -> WebAssembly toolchain ready."
            echo "Run ./scripts/build.sh, then ./scripts/serve.sh"
          '';
        };

        devShells.test = pkgs.mkShell {
          packages = [ wasmTools pkgs.chromium npmDeps ];
          shellHook = ''
            export CHROMIUM="${pkgs.chromium}/bin/chromium"
            export NODE_PATH="${npmDeps}/lib/node_modules/@haskell-wasm/ghc-wasm-npm-deps/node_modules"
            echo "Test shell ready: node scripts/test-node.mjs / scripts/test-browser.mjs"
          '';
        };
      });
}

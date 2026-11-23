{
  description = "Offline-first Haskell time tracker (browser/WebAssembly + Android APK)";

  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    ghc-wasm.url = "github:haskell-wasm/ghc-wasm-meta";
  };

  outputs = { self, flake-utils, ghc-wasm }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        wasmTools = ghc-wasm.packages.${system}.default;
        pkgs = import ghc-wasm.inputs.nixpkgs {
          inherit system;
          config = {
            allowUnfree = true;
            android_sdk.accept_license = true;
          };
        };
        npmDeps = ghc-wasm.packages.${system}.npm-deps;
        androidSdk = pkgs.androidenv.composeAndroidPackages {
          platformVersions = [ "35" ];
          buildToolsVersions = [ "37.0.0" ];
          includeEmulator = false;
          includeSystemImages = false;
        };
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

        devShells.android = pkgs.mkShell {
          packages = [ wasmTools pkgs.gradle pkgs.jdk17 androidSdk.androidsdk ];
          shellHook = ''
            export ANDROID_HOME="${androidSdk.androidsdk}/libexec/android-sdk"
            export ANDROID_SDK_ROOT="$ANDROID_HOME"
            export JAVA_HOME="${pkgs.jdk17}"
            export PATH="$JAVA_HOME/bin:$PATH"
            echo "Android build shell ready."
            echo "Run ./scripts/build-apk.sh to produce release/time-tracking.apk"
          '';
        };
      });
}

#!/usr/bin/env bash
# Bundle the static PWA into an installable Android APK (no Play Services).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

command -v gradle >/dev/null || {
  echo "error: gradle not found. Run 'nix develop .#android' first." >&2
  exit 1
}
[ -n "${ANDROID_HOME:-}" ] || {
  echo "error: ANDROID_HOME is not set. Run 'nix develop .#android' first." >&2
  exit 1
}

# Make sure the wasm and icons match the current sources.
"$ROOT/scripts/build.sh"

WEB_ASSETS="android/app/src/main/assets/web"
rm -rf "$WEB_ASSETS"
mkdir -p "$WEB_ASSETS"
cp -a web/. "$WEB_ASSETS/"

# Reuse the PWA icon as the launcher icon.
mkdir -p android/app/src/main/res/drawable-nodpi
cp web/icons/icon-192.png android/app/src/main/res/drawable-nodpi/ic_launcher.png

echo
echo "Building APK…"
# AGP downloads a glibc-linked aapt2 that cannot run on NixOS, so use the one
# shipped with the Nix Android SDK instead.
AAPT2="$ANDROID_HOME/build-tools/37.0.0/aapt2"
( cd android && gradle --no-daemon \
    -Pandroid.aapt2FromMavenOverride="$AAPT2" \
    assembleDebug )

mkdir -p release
cp android/app/build/outputs/apk/debug/app-debug.apk release/time-tracking.apk

echo
echo "APK ready: release/time-tracking.apk"
echo "Install with: adb install -r release/time-tracking.apk"

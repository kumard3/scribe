#!/bin/bash
# Build Scribe.app (menu-bar dictation agent) from the SPM executable.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"

# Prebuilt sherpa-onnx C library (universal2) for the downloadable models.
SHERPA_VER="v1.13.2"
SHERPA_NAME="sherpa-onnx-${SHERPA_VER}-osx-universal2-shared"
SHERPA_DIR=".deps/${SHERPA_NAME}"
if [ ! -f "$SHERPA_DIR/lib/libsherpa-onnx-c-api.dylib" ]; then
  echo "Fetching sherpa-onnx ${SHERPA_VER}…"
  mkdir -p .deps
  curl -sL -o .deps/sherpa.tar.bz2 \
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/${SHERPA_VER}/${SHERPA_NAME}.tar.bz2"
  tar xjf .deps/sherpa.tar.bz2 -C .deps
  rm -f .deps/sherpa.tar.bz2
fi
cp "$SHERPA_DIR/include/sherpa-onnx/c-api/c-api.h" Sources/CSherpa/include/c-api.h

echo "Building Scribe ($CONFIG)…"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/Scribe"
APP="Scribe.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Scribe"
cp Info.plist "$APP/Contents/Info.plist"
cp "$SHERPA_DIR/lib/libsherpa-onnx-c-api.dylib" "$APP/Contents/Frameworks/"
cp "$SHERPA_DIR/lib/libonnxruntime.1.24.4.dylib" "$APP/Contents/Frameworks/"

# App icon from the mobile app's icon.png
if [ -f ../assets/icon.png ] && [ ! -f Scribe.icns ]; then
  ICONSET=$(mktemp -d)/Scribe.iconset
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s ../assets/icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) ../assets/icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o Scribe.icns
fi
[ -f Scribe.icns ] && cp Scribe.icns "$APP/Contents/Resources/Scribe.icns"

# Sign with a real identity when available — TCC grants (mic / speech /
# accessibility) only survive rebuilds with a stable signature. Ad-hoc
# fallback means re-granting permissions after every build.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/{print $2; exit}')
codesign --force --sign "${IDENTITY:--}" "$APP/Contents/Frameworks/"*.dylib >/dev/null 2>&1 || true
codesign --force --deep --sign "${IDENTITY:--}" "$APP" >/dev/null 2>&1 || true

echo "Built $(pwd)/$APP"
echo "Run it with:  open $(pwd)/$APP    (then grant Mic, Speech, and Accessibility)"

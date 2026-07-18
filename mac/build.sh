#!/bin/bash
# Build Scribe.app (menu-bar dictation agent) from the SPM executable.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"

# Prebuilt sherpa-onnx C library (universal2) for the downloadable models.
# v1.13.3+ is required for multilingual Nemotron-3.5 streaming (prompt_index).
SHERPA_VER="v1.13.3"
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

# llama.cpp (Metal, universal2) built from source for the on-device text AI
# (Gemma 4 — AI Cleanup & Summary). Pin a tag via LLAMA_TAG if master drifts past
# the C API the CLlama shim targets.
LLAMA_TAG="${LLAMA_TAG:-master}"
LLAMA_LIB=".deps/llama/lib"
if [ ! -f "$LLAMA_LIB/libllama.dylib" ]; then
  command -v cmake >/dev/null || { echo "cmake required — install with: brew install cmake"; exit 1; }
  echo "Building llama.cpp ($LLAMA_TAG, Metal, universal2)… first build is slow."
  rm -rf .deps/llama-src .deps/llama-build
  git clone --depth 1 --branch "$LLAMA_TAG" https://github.com/ggml-org/llama.cpp .deps/llama-src
  cmake -S .deps/llama-src -B .deps/llama-build \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=ON \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
    -DLLAMA_CURL=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TOOLS=OFF \
    -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"
  # Build only the libraries the app links/loads — llama.cpp master's app/ and
  # tool targets drift and fail (e.g. missing build-info.h), and we don't ship them.
  cmake --build .deps/llama-build --config Release -j \
    --target llama ggml ggml-base ggml-cpu ggml-metal ggml-blas
  mkdir -p "$LLAMA_LIB" Sources/CLlama/vendor
  find .deps/llama-build -name "*.dylib" -exec cp {} "$LLAMA_LIB/" \;
  cp .deps/llama-src/include/llama.h Sources/CLlama/vendor/
  cp .deps/llama-src/ggml/include/*.h Sources/CLlama/vendor/
fi

echo "Building Scribe ($CONFIG)…"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/Scribe"
APP="Scribe.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Scribe"
cp Info.plist "$APP/Contents/Info.plist"
cp "$SHERPA_DIR/lib/libsherpa-onnx-c-api.dylib" "$APP/Contents/Frameworks/"
cp "$SHERPA_DIR/lib/"libonnxruntime*.dylib "$APP/Contents/Frameworks/"
cp "$LLAMA_LIB/"*.dylib "$APP/Contents/Frameworks/" 2>/dev/null || true

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

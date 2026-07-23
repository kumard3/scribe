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

# Silero VAD (~630 KB) segments long audio at silence so the non-streaming
# recognizers never decode more than ~8 s at once, without it Moonshine returns
# empty text and balloons to 15 GB+ on a minute of speech.
if [ ! -f ".deps/silero_vad.onnx" ]; then
  echo "Fetching silero_vad.onnx…"
  curl -sL -o .deps/silero_vad.onnx \
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx"
fi

# llama.cpp (Metal, universal2) built from source for the on-device text AI
# (Gemma 4, AI Cleanup & Summary). Pin a tag via LLAMA_TAG if master drifts past
# the C API the CLlama shim targets.
LLAMA_TAG="${LLAMA_TAG:-master}"
LLAMA_LIB=".deps/llama/lib"
if [ ! -f "$LLAMA_LIB/libllama.dylib" ]; then
  command -v cmake >/dev/null || { echo "cmake required, install with: brew install cmake"; exit 1; }
  echo "Building llama.cpp ($LLAMA_TAG, Metal, universal2)… first build is slow."
  rm -rf .deps/llama-src .deps/llama-build
  git clone --depth 1 --branch "$LLAMA_TAG" https://github.com/ggml-org/llama.cpp .deps/llama-src
  # LLAMA_BUILD_TOOLS=ON is needed for the mtmd LIBRARY target (audio input for
  # Srota / Qwen3-ASR), but only library targets are built; llama.cpp master's
  # app/ and tool executables drift and fail (e.g. missing build-info.h).
  cmake -S .deps/llama-src -B .deps/llama-build \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=ON \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
    -DLLAMA_CURL=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TOOLS=ON \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
    -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"
  cmake --build .deps/llama-build --config Release -j \
    --target llama mtmd ggml ggml-base ggml-cpu ggml-metal ggml-blas
  mkdir -p "$LLAMA_LIB" Sources/CLlama/vendor
  find .deps/llama-build \( -path "*/bin/*.dylib" -o -path "*/src/*.dylib" -o -path "*/ggml/*.dylib" \) -name "*.dylib" -exec cp {} "$LLAMA_LIB/" \;
  cp .deps/llama-src/include/llama.h Sources/CLlama/vendor/
  cp .deps/llama-src/ggml/include/*.h Sources/CLlama/vendor/
  cp .deps/llama-src/tools/mtmd/mtmd.h .deps/llama-src/tools/mtmd/mtmd-helper.h Sources/CLlama/vendor/
fi

# whisper.cpp is kept in a private helper directory so its ggml ABI cannot
# collide with llama.cpp's different ggml version in the main executable.
# The Q5 Hinglish model itself is an optional Dashboard download.
WHISPER_TAG="v1.9.1"
WHISPER_SRC=".deps/whisper-src"
WHISPER_BUILD=".deps/whisper-universal-build"
WHISPER_DIST=".deps/whisper/bin"
WHISPER_CLI="$WHISPER_DIST/whisper-cli"
if [ ! -x "$WHISPER_CLI" ] || ! lipo -archs "$WHISPER_CLI" | grep -qw x86_64; then
  if [ ! -d "$WHISPER_SRC/.git" ]; then
    git clone --depth 1 --branch "$WHISPER_TAG" \
      https://github.com/ggml-org/whisper.cpp "$WHISPER_SRC"
  fi
  echo "Building whisper.cpp ($WHISPER_TAG, Metal, universal2)…"
  cmake -S "$WHISPER_SRC" -B "$WHISPER_BUILD" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
    -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" -DGGML_NATIVE=OFF \
    -DGGML_METAL=ON -DWHISPER_BUILD_EXAMPLES=ON \
    -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF
  cmake --build "$WHISPER_BUILD" --config Release -j --target whisper-cli
  mkdir -p "$WHISPER_DIST"
  cp -L "$WHISPER_BUILD/bin/"*.dylib "$WHISPER_DIST/"
  cp "$WHISPER_BUILD/bin/whisper-cli" "$WHISPER_CLI"
  install_name_tool -add_rpath @executable_path "$WHISPER_CLI"
fi

echo "Building Scribe ($CONFIG)…"
swift build -c "$CONFIG" --arch arm64 --arch x86_64

case "$CONFIG" in
  release) PRODUCT_CONFIG="Release" ;;
  debug) PRODUCT_CONFIG="Debug" ;;
  *) echo "Unsupported configuration: $CONFIG"; exit 1 ;;
esac
BIN=".build/apple/Products/$PRODUCT_CONFIG/Scribe"
APP="Scribe.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" \
  "$APP/Contents/Frameworks" "$APP/Contents/Helpers/Whisper"
cp "$BIN" "$APP/Contents/MacOS/Scribe"
ditto ".build/apple/Products/$PRODUCT_CONFIG/Sparkle.framework" \
  "$APP/Contents/Frameworks/Sparkle.framework"
cp Info.plist "$APP/Contents/Info.plist"
cp .deps/silero_vad.onnx "$APP/Contents/Resources/silero_vad.onnx"
cp "$SHERPA_DIR/lib/libsherpa-onnx-c-api.dylib" "$APP/Contents/Frameworks/"
cp "$SHERPA_DIR/lib/"libonnxruntime*.dylib "$APP/Contents/Frameworks/"
cp "$LLAMA_LIB/"*.dylib "$APP/Contents/Frameworks/" 2>/dev/null || true
cp "$WHISPER_DIST/"*.dylib "$APP/Contents/Helpers/Whisper/"
cp "$WHISPER_CLI" "$APP/Contents/Helpers/Whisper/whisper-cli"
cp "$WHISPER_SRC/LICENSE" "$APP/Contents/Resources/whisper.cpp-LICENSE"

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

# Prefer a Developer ID identity for public releases; use Apple Development for
# local builds, then ad-hoc only on machines with no signing identity. Release
# signing errors are fatal so CI can never upload an unsigned archive.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/{print $2; exit}')
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/{print $2; exit}')
fi
if [ "${SCRIBE_REQUIRE_DEVELOPER_ID:-0}" = "1" ] &&
   [[ "$IDENTITY" != Developer\ ID\ Application:* ]]; then
  echo "Developer ID Application certificate is required for a public release."
  exit 1
fi
SIGN_IDENTITY="${IDENTITY:--}"
SIGN_ARGS=(--force --sign "$SIGN_IDENTITY")
if [[ "$IDENTITY" == Developer\ ID\ Application:* ]]; then
  SIGN_ARGS+=(--options runtime --timestamp)
fi
codesign "${SIGN_ARGS[@]}" "$APP/Contents/Frameworks/"*.dylib
codesign "${SIGN_ARGS[@]}" "$APP/Contents/Helpers/Whisper/"*.dylib
codesign "${SIGN_ARGS[@]}" "$APP/Contents/Helpers/Whisper/whisper-cli"
codesign --deep "${SIGN_ARGS[@]}" "$APP"
codesign --verify --deep --strict "$APP"

echo "Built $(pwd)/$APP"
echo "Run it with:  open $(pwd)/$APP    (then grant Mic, Speech, and Accessibility)"

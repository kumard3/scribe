#!/bin/bash
set -euo pipefail

MODEL_DIR="${1:?usage: export-q5.sh HF_MODEL_DIR OUTPUT_DIR}"
OUTPUT_DIR="${2:?usage: export-q5.sh HF_MODEL_DIR OUTPUT_DIR}"
WHISPER_CPP="${WHISPER_CPP:?set WHISPER_CPP to a whisper.cpp checkout}"
OPENAI_WHISPER="${OPENAI_WHISPER:?set OPENAI_WHISPER to an openai/whisper checkout}"

mkdir -p "$OUTPUT_DIR"
cmake -S "$WHISPER_CPP" -B "$WHISPER_CPP/build" \
  -DCMAKE_BUILD_TYPE=Release -DWHISPER_BUILD_TESTS=OFF
cmake --build "$WHISPER_CPP/build" --config Release -j --target quantize
python3 "$WHISPER_CPP/models/convert-h5-to-ggml.py" \
  "$MODEL_DIR" "$OPENAI_WHISPER" "$OUTPUT_DIR"
mv "$OUTPUT_DIR/ggml-model.bin" "$OUTPUT_DIR/hinglish-whisper-small-f16.bin"
"$WHISPER_CPP/build/bin/quantize" \
  "$OUTPUT_DIR/hinglish-whisper-small-f16.bin" \
  "$OUTPUT_DIR/hinglish-whisper-small-q5_0.bin" q5_0
shasum -a 256 "$OUTPUT_DIR/hinglish-whisper-small-q5_0.bin"

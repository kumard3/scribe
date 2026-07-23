#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
MAC_DIR=${SCRIPT_DIR:h}
APP=${MAC_DIR}/Scribe.app/Contents/MacOS/Scribe
MODEL_DIR="$HOME/Library/Application Support/Scribe/models/nemo-parakeet-ctc-110m-en/sherpa-onnx-nemo-parakeet_tdt_ctc_110m-en-36000-int8"
SOURCE_WAV=${MODEL_DIR}/test_wavs/0.wav
WORK_DIR=$(mktemp -d /tmp/scribe-memory-regression.XXXXXX)
trap 'rm -rf -- "$WORK_DIR"' EXIT

if [[ ! -x "$APP" ]]; then
  print -u2 "Build Scribe.app first: cd mac && ./build.sh"
  exit 2
fi
if [[ ! -f "$SOURCE_WAV" ]]; then
  print -u2 "Download Parakeet 110M in Scribe before running this test"
  exit 2
fi

ffmpeg -v error -stream_loop 8 -i "$SOURCE_WAV" -t 60 \
  -ar 16000 -ac 1 -c:a pcm_f32le "$WORK_DIR/sixty-seconds.wav" -y

START=$(date +%s)
 /usr/bin/time -l "$APP" \
  --transcribe "$WORK_DIR/sixty-seconds.wav" nemo-parakeet-ctc-110m-en \
  --provider cpu \
  >"$WORK_DIR/transcript.txt" 2>"$WORK_DIR/metrics.txt"
ELAPSED=$(($(date +%s) - START))
RSS=$(awk '/maximum resident set size/ { print $1 }' "$WORK_DIR/metrics.txt" | tail -1)

[[ -n "$RSS" ]] || { print -u2 "Could not read maximum RSS"; exit 1; }
(( ELAPSED < 60 )) || { print -u2 "FAIL: ${ELAPSED}s (limit 59s)"; exit 1; }
(( RSS < 1500000000 )) || { print -u2 "FAIL: ${RSS} bytes RSS (limit 1.5 GB)"; exit 1; }

# Exercise the real app → worker → app boundary as a separate assertion. BSD
# time reports only the parent RSS, so the direct invocation above is retained
# as the native decoder's memory measurement.
"$APP" --worker-transcribe "$WORK_DIR/sixty-seconds.wav" \
  nemo-parakeet-ctc-110m-en --provider cpu >"$WORK_DIR/worker-transcript.txt"
[[ -s "$WORK_DIR/worker-transcript.txt" ]] || { print -u2 "Worker produced no transcript"; exit 1; }

print "PASS: ${ELAPSED}s, $((RSS / 1000000)) MB max RSS, worker isolation OK"

#!/usr/bin/env bash
# Symbol-check a built .app and launch it on a real iPhone, failing if it dies.
#
# App Review rejected 1.0 (8) under guideline 2.1(a): dyld aborted with "Symbol missing"
# before any app code ran. 1.0 (9) then trapped in UIKit for lacking a scene manifest.
# Neither had been launched before submitting; ios-release.sh --upload now needs this to pass.
#
# Simulators cannot run this app on Apple Silicon: CocoaPods sets
# EXCLUDED_ARCHS[sdk=iphonesimulator*] = arm64 (MLKit ships no arm64 simulator slice),
# so the simulator build is x86_64 and macOS 27 has no Rosetta for it.
#
# usage: scripts/ios-preflight.sh [path/to/App.app]
set -euo pipefail

cd "$(dirname "$0")/.."
APP=${1:-$(ls -d ~/Library/Developer/Xcode/DerivedData/Scribe-*/Build/Products/Release-iphoneos/Scribe.app 2>/dev/null | head -1)}
DEVICE=${DEVICE:-00008150-000A684214F2401C}
HOLD_SECONDS=${HOLD_SECONDS:-12}

[ -n "$APP" ] && [ -d "$APP" ] || { echo "no .app found, pass one as \$1"; exit 1; }
echo "== app: $APP"

echo "== symbol check"
python3 scripts/check-app-symbols.py "$APP"

echo "== installing on $DEVICE"
xcrun devicectl device install app --device "$DEVICE" "$APP" > /tmp/ios-preflight-install.json 2>&1 ||
  { tail -5 /tmp/ios-preflight-install.json; exit 1; }
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Info.plist")

xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID" > /tmp/ios-preflight-launch.txt 2>&1 ||
  { echo "LAUNCH FAILED"; tail -8 /tmp/ios-preflight-launch.txt; exit 1; }
EXE=$(basename "$APP" .app)
echo "== launched, holding ${HOLD_SECONDS}s"
sleep "$HOLD_SECONDS"

PID=$(xcrun devicectl device info processes --device "$DEVICE" 2>/dev/null |
  awk -v e="/$EXE.app/$EXE\$" '$2 ~ e {print $1; exit}')
if [ -n "$PID" ]; then
  echo "PREFLIGHT PASSED: pid $PID still alive after ${HOLD_SECONDS}s"
  mkdir -p ~/.cache/bolkit-preflight
  touch ~/.cache/bolkit-preflight/"$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Info.plist")"
else
  echo "PREFLIGHT FAILED: no $EXE process on the device"
  exit 1
fi

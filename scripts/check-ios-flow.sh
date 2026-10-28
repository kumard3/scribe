#!/bin/bash
# Checks the native Flow pieces that run without JS: the Swift voice-command port in
# ios/Scribe/VoiceCommands.swift must match applyVoiceCommands in src/util/polish.ts, and
# FlowShared requests must be one-shot, action-bound and expire after 5 s.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/bolkit-ios-flow"
mkdir -p "$OUT"

cat > "$OUT/cases.json" <<'JSON'
[
  "no no no delete everything that I said till now the meeting is on Friday",
  "hello world. Delete everything. New text here",
  "first draft scratch all of that second draft",
  "first draft, scratch all of that. second draft",
  "please delete everything in the downloads folder",
  "delete everything before Friday",
  "delete everything I said before. new start",
  "wrong stuff start over. right stuff",
  "erase everything I said so far okay take two",
  "delete everything",
  "okay wait, clear it all and start over. take three",
  "forget everything I’ve dictated before let's go",
  "we need to start over with the design",
  "send the report scratch that",
  "call mom. send the report scratch that",
  "buy milk eggs delete the last word bread",
  "line one\nline two\ndelete the last line\nline three",
  "line one\nkeep this scratch last line",
  "nothing to change here"
]
JSON

cat > "$OUT/main.swift" <<'SWIFT'
import Foundation

FlowShared.directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let id = FlowShared.request(FlowShared.start)
precondition(FlowShared.takeRequest(FlowShared.stop) == nil, "a start request must not satisfy stop")
precondition(FlowShared.takeRequest(FlowShared.start) == id, "fresh request is accepted")
precondition(FlowShared.takeRequest(FlowShared.start) == nil, "a request is consumed once")
let stale = FlowRequest(id: "old", action: FlowShared.start, at: Date().addingTimeInterval(-6))
try! JSONEncoder().encode(stale).write(to: FlowShared.directory!.appendingPathComponent("request.json"))
precondition(FlowShared.takeRequest(FlowShared.start) == nil, "a 6 s old request is rejected")
precondition(FlowShared.takeRequest(FlowShared.start, within: 15) == "old", "the URL path allows 15 s")
FileHandle.standardError.write("flow requests: ok\n".data(using: .utf8)!)

let cases = try! JSONDecoder().decode([String].self, from: FileHandle.standardInput.readDataToEndOfFile())
print(String(data: try! JSONEncoder().encode(cases.map(VoiceCommands.apply)), encoding: .utf8)!)
SWIFT

swiftc -O -o "$OUT/check" "$ROOT/ios/Scribe/VoiceCommands.swift" "$ROOT/ios/Shared/FlowShared.swift" "$OUT/main.swift"
SWIFT_OUT="$("$OUT/check" "$OUT" < "$OUT/cases.json")"
JS_OUT="$(cd "$ROOT" && bun -e "import { applyVoiceCommands } from './src/util/polish.ts'; console.log(JSON.stringify(JSON.parse(await Bun.stdin.text()).map(applyVoiceCommands)))" < "$OUT/cases.json")"

python3 - "$SWIFT_OUT" "$JS_OUT" <<'PY'
import json, sys
swift, js = json.loads(sys.argv[1]), json.loads(sys.argv[2])
bad = [(i, s, j) for i, (s, j) in enumerate(zip(swift, js)) if s != j]
for i, s, j in bad:
    print(f"case {i}: swift={s!r} js={j!r}")
sys.exit(1 if bad or len(swift) != len(js) else print(f"voice commands: {len(js)} cases match"))
PY

# Scribe for Windows

System-wide local dictation, same design as the Mac app: hold a key, speak,
release — the text is typed into whatever app has focus. 100% offline
(sherpa-onnx streaming zipformer, runs on CPU).

## How it works

- **Hold Right Ctrl** (configurable) — push-to-talk: record while held,
  release to insert.
- **Tap Right Ctrl** — hands-free: keeps recording until the next tap
  (can be turned off in the dashboard).
- A black pill at the bottom of the screen shows live levels + partial text,
  then "Inserted" when the text lands.
- Inserting uses Ctrl+V but **restores your previous clipboard** afterwards.
- **Dashboard** (tray icon double-click or menu): pureMono black UI matching
  the mobile app — change the hold key (Right Ctrl / Right Alt / Caps Lock /
  F8 / Scroll Lock / Pause), hands-free toggle, launch at startup, and a
  recent-transcripts list. Settings persist in
  `%LOCALAPPDATA%\Scribe\settings.json`.
- First launch downloads the speech model once (~370 MB) to
  `%LOCALAPPDATA%\Scribe\models` — the pill shows progress.

## Build (on Windows)

Requires the [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0).

```powershell
cd windows\Scribe
dotnet run -c Release            # build + run
# or produce a standalone exe:
dotnet publish -c Release -r win-x64 --self-contained -p:PublishSingleFile=true
# → bin\Release\net8.0-windows\win-x64\publish\Scribe.exe
```

The project cross-compiles on macOS/Linux for CI-style checks with
`dotnet build /p:EnableWindowsTargeting=true`, but it can only *run* on
Windows (WinForms + the sherpa-onnx native runtime).

## Notes

- The streaming API follows the official sherpa-onnx `dotnet-examples`
  (speech-recognition-from-microphone): `OnlineRecognizer` + `AcceptWaveform`
  / `IsReady` / `Decode` / `GetResult` / `IsEndpoint` / `Reset`.
- No audio or text ever leaves the machine.

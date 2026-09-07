# Scribe

Free on-device dictation. Speak, and text appears in whatever app you are using. Audio never leaves your device: no servers, no account, no API keys, no cost.

**[Download the latest release](https://github.com/kumard3/scribe/releases/latest)** · [Website](https://scribe-site.kumard3.workers.dev)

## Platforms

Each desktop OS has **its own dedicated tree and build**. They do not share an engine.

| Platform | Code | Build | Engine |
|---|---|---|---|
| macOS | `mac/` | `cd mac && ./build.sh` (Swift / AppKit) | MLX + llama.cpp + whisper.cpp + Apple Speech |
| Windows | `windows/Scribe/` | `dotnet build -c Release` (.NET 8 WinForms) | sherpa-onnx, GPU auto (CUDA / DirectML / CPU) |
| Android | `android/` + `src/` | `npx expo run:android` | mobile ASR stack |
| iOS | `ios/` + `src/` | `npx expo run:ios` | mobile ASR stack |

There is no Linux desktop app yet. Linux would get its own folder, not a port of `mac/` or `windows/`.

## What it does

- **Dictation into any app.** Hold a hotkey, speak, release. Text lands at your cursor.
- **Your choice of model.** Whisper, Parakeet, Moonshine, Canary, Dolphin, Nemotron, and Srota (Hinglish). Download the ones you want, each tagged by size and quality.
- **Hinglish.** Hindi comes out in English letters ("ab isko badalne ke liye"), the way people actually type it. Toggleable.
- **Spoken commands.** "next line", "new paragraph", "point one" for numbered lists, "bullet" for dashes, "scratch that" to undo a line.
- **AI cleanup and summary.** Optional on-device Gemma model polishes the transcript. Also fully local.
- **Light on memory.** Models load on demand and unload after 5 minutes idle.

## Build from source

macOS (Swift, menu bar app):

```bash
cd mac && ./build.sh
open Scribe.app   # grant Mic, Speech, and Accessibility
```

Mobile (Expo, native build required, does not run in Expo Go):

```bash
npx expo run:ios      # or run:android
```

Windows (C# tray app, separate from Mac):

```powershell
cd windows\Scribe
dotnet build -c Release
dotnet publish -c Release -r win-x64 --self-contained -p:PublishSingleFile=true
```

## Privacy

Everything runs on your device. No telemetry, no network calls except model downloads. See the [privacy policy](https://scribe-site.kumard3.workers.dev/privacy).

## License

MIT

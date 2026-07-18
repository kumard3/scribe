# Scribe

Free on-device dictation. Speak, and text appears in whatever app you are using. Audio never leaves your device: no servers, no account, no API keys, no cost.

**[Download the latest release](https://github.com/kumard3/scribe/releases/latest)** · [Website](https://scribe-site.kumard3.workers.dev)

## Platforms

| Platform | Status | Where |
|---|---|---|
| macOS | v1.2.0 | Menu bar app, hold `fn` to talk. `Scribe-macOS.zip` in releases |
| Android | beta | APK in [v1.0.0-beta](https://github.com/kumard3/scribe/releases/tag/v1.0.0-beta) |
| Windows | beta | Tray app, same release |
| iOS | source only | Build with Expo, see below |

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

Windows: `windows/` contains a .NET 8 tray app, build with `dotnet publish`.

## Privacy

Everything runs on your device. No telemetry, no network calls except model downloads. See the [privacy policy](https://scribe-site.kumard3.workers.dev/privacy).

## License

MIT

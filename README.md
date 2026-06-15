# Vox

**Say it. See it.** On-device speech to text. No server, no API keys, no per-user cost. Three engines, all fully local:

- **Live mode (default).** The phone's built-in on-device speech recognition (iOS `SFSpeechRecognizer`, Android `SpeechRecognizer`). Real-time streaming transcript, automatic punctuation, ~25 languages, **zero downloads**. This is the primary talk-and-see-text experience and it works on Android too (the OS owns the mic).
- **Offline mode (Whisper).** Whisper (whisper.cpp via whisper.rn) for record-then-transcribe with optional translate-to-English, and for languages the system can't do on-device.
- **More engines (sherpa-onnx).** Downloadable ONNX models — Moonshine (English), and the path to NVIDIA Parakeet, SenseVoice, and speaker diarization. Pick one in **Models → "Use"** and Offline mode routes through it.

Live mode keeps the screen awake while recording and auto-resumes if iOS pauses recognition. Transcripts are editable, searchable, and shareable.

## Run it (iOS)

This app has native code, so it needs a **development/release build** — it does **not** run in Expo Go.

```bash
cd localvoice
npx expo run:ios            # builds the native app + launches it
```

Usage:
1. **Live** is selected by default. Pick a language, tap the mic, and watch text appear as you speak. Tap again to stop.
2. Switch to **Offline** for record-then-transcribe with Whisper (and the Translate → EN toggle).

To run on a physical iPhone: `npx expo run:ios --device` and select your phone (needs a free Apple developer signing team in Xcode the first time).

## How it works

```
            Live    → system speech recognition (SFSpeechRecognizer / Android SpeechRecognizer)
 tap mic ──┤          streaming partial+final results, on-device, punctuation, no download
            Offline → mic (expo-audio WAV) → router.resolveModel(language)
                      → modelManager (download + cache) → WhisperEngine (whisper.rn, Metal)
                      → transcript (+ optional translate-to-English)
```

Live mode lives in `src/asr/system.ts` (wraps `expo-speech-recognition`) and is driven by event hooks in `App.tsx`. Offline mode is the engine-agnostic Whisper path below.

### Per-language model routing — `src/asr/registry.ts`

This is the core design: each language maps to the best available model, with a multilingual all-in-one fallback.

```
auto → whisper-tiny-multi   (all-in-one, 75 MB)
en   → whisper-base-en      (English-tuned, 142 MB)
hi   → whisper-small-multi  (best Whisper-family for Hindi, 466 MB)
…    → whisper-small-multi  (default for other languages)
```

To use a **better model for a specific language** (e.g. a fine-tuned Hindi model, or NVIDIA Parakeet for English), add a `ModelSpec` to `MODELS` and point that language's entry in `LANGUAGE_ROUTES` at it. The engine is selected per-model via `ModelSpec.engine`, so different languages can run on different engines.

### Engine-agnostic core — `src/asr/`

| File | Responsibility |
|---|---|
| `types.ts` | `ASREngine` interface + `ModelSpec` |
| `registry.ts` | model catalog + language→model routes |
| `router.ts` | pick the model for a language |
| `modelManager.ts` | download / cache / delete model files |
| `whisperEngine.ts` | whisper.rn implementation of `ASREngine` |
| `index.ts` | `prepare()` and `transcribeFile()` facade the UI calls |

Adding a new engine = implement `ASREngine` and register it in `index.ts`'s `engines` map.

## Roadmap

- **Live mode — done.** Real-time on-device dictation with punctuation on iOS + Android via `expo-speech-recognition`. This also sidesteps the Android WAV problem for the primary flow (the OS captures audio directly).
- **Offline Android.** `expo-audio` can only emit AAC/AMR on Android, but whisper.cpp needs WAV/PCM. Offline (Whisper) mode therefore still needs a raw-PCM recorder on Android (e.g. `expo-speech-recognition`'s `recordingOptions.persist`, which writes 16 kHz WAV, or a PCM-stream lib). Live mode already covers Android with no extra work.
- **NVIDIA models (Parakeet / Canary).** Optional offline upgrade: add a `SherpaEngine` (sherpa-onnx) implementing `ASREngine`. Canary = speech-to-text **+ translation** across 25 languages in one model; Parakeet = fastest English ASR. Register their ONNX models in `registry.ts` and route the relevant languages to them.
- **Best-per-language Indic.** For Hindi/Indic where the system on-device model is weak, route Offline mode to AI4Bharat IndicConformer (MIT, all 22 Indian languages, ~130 MB INT8) via the Sherpa engine.
- **Speaker diarization.** "Who spoke" labels via sherpa-onnx speaker-segmentation models (offline path).
- **Mac / desktop.** Reuse this same router design in a **Tauri** app; on the desktop, macOS `SFSpeechRecognizer` covers the live path and whisper.cpp/NeMo covers offline.

## Why fully local
Privacy (audio never leaves the device), zero inference cost (free for users), and offline operation. The tradeoff is app size / model download — solved with per-language download-on-demand packs instead of bundling everything.

# LocalVoice

On-device speech → text and translation. No server, no API keys, no per-user cost. Models run entirely on the device and are downloaded per-language on first use.

**v1 scope:** iOS (working), record-then-transcribe, Whisper engine, per-language model routing. Android and the NVIDIA (Parakeet/Canary) engines are scaffolded but not wired yet — see _Roadmap_.

## Run it (iOS)

This app has native code (whisper.cpp), so it needs a **development build** — it does **not** run in Expo Go.

```bash
cd localvoice
npx expo run:ios            # builds the native app + launches the simulator
```

First launch:
1. Pick a language chip (English is the default).
2. Tap **Download model** (English = ~142 MB, downloaded once, cached on device).
3. Tap **Tap to talk**, speak, then **Stop & transcribe**.
4. Flip **Translate to English** to get translation instead of transcription.

To run on a physical iPhone: `npx expo run:ios --device` and select your phone (needs a free Apple developer signing team in Xcode the first time).

## How it works

```
mic (expo-audio, 16 kHz mono WAV)
        │
        ▼
  router.resolveModel(language)        ← per-language model routing
        │
        ▼
  modelManager (download + cache)      ← expo-file-system, per-language packs
        │
        ▼
  WhisperEngine (whisper.rn / whisper.cpp, Metal-accelerated)
        │
        ▼
  transcript (+ optional translate-to-English)
```

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

- **Android.** `expo-audio` can only emit AAC/AMR on Android, but whisper.cpp needs WAV/PCM. Swap the recorder for a raw-PCM stream (e.g. `@fugood/react-native-audio-pcm-stream`) and write a WAV header — this also unlocks live/streaming transcription and VAD.
- **Live "detection" mode.** whisper.rn 0.6 ships `RealtimeTranscriber` + a VAD context (`initWhisperVad`). Feed it the PCM stream above for continuous talk-and-see-text with voice-activity detection.
- **NVIDIA models (Parakeet / Canary).** Add a `SherpaEngine` (sherpa-onnx) implementing `ASREngine`. Parakeet = fastest English ASR; Canary = speech-to-text **+ translation** across 25 languages in one model. Register their ONNX models in `registry.ts` and route the relevant languages to them. The full 1B Canary is desktop-class; phones use the ~180 MB on-device variant or quantized models.
- **Mac / desktop.** Reuse this same model-router design in a **Tauri** app (or run the full Canary-1B via whisper.cpp/NeMo locally).

## Why fully local
Privacy (audio never leaves the device), zero inference cost (free for users), and offline operation. The tradeoff is app size / model download — solved with per-language download-on-demand packs instead of bundling everything.

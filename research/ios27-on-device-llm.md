# iOS 27 / macOS 27: Apple on-device LLM and speech for Bolkit

Sources: [SDK] = iPhoneOS.sdk (iOS 27.0) swiftinterfaces in Xcode 27.0. [PROBE] = Swift script run on this M3 Pro Mac, macOS 27.0. [WWDC] = WWDC26 session 319. [SUPPORT] = support.apple.com/en-in/121115 (published 2026-09-15).

## Models and APIs
- `SystemLanguageModel` (on-device, iOS 26+) now conforms to a new `LanguageModel` protocol (iOS 27). New `variant` with `.core3` and `.coreAdvanced3`. Confirmed [SDK]. Probe reports variant "AFM 3 Core" [PROBE].
- Context: `contextSize` is 4096 on 26, 8192 on 27 "newer devices" [WWDC]. Returned 0 here because the model was `modelNotReady` [PROBE].
- New `PrivateCloudComputeLanguageModel` (iOS/macOS 27): server model, 32K context, reasoning levels, per-user daily quota (`quotaUsage`, `QuotaLimitReached`), apps under 2M downloads, must apply on the developer site [SDK][WWDC]. Not on-device.
- Unchanged pieces: `LanguageModelSession`, `@Generable`, `Tool`, `Guardrails.permissiveContentTransformations`, `tokenCount` (26.4) [SDK]. Custom `Adapter` is obsoleted in 27 [SDK].
- Speech: `SpeechAnalyzer`, `SpeechTranscriber` (presets incl. `progressiveTranscription`), `DictationTranscriber`, `AssetInventory`, `AnalysisContext.contextualStrings` [SDK].

## Languages
- Foundation Models: 24 locales, includes `en-IN`, **no Hindi** (`supportsLocale(hi-IN) == false`) [PROBE]. Apple Intelligence language list has no Hindi [SUPPORT].
- SpeechTranscriber: 45 locales incl. `hi_IN`, `en_IN`, `mul_IN`, and 12 other Indian languages; DictationTranscriber includes `hi_IN` and `en_IN` [PROBE]. What `mul_IN` does (code-switched Hinglish?) is inferred, needs a device test.

## Device and region requirements [SUPPORT]
iPhone 15 Pro and later, M1+ iPad/Mac; Apple Intelligence enabled; device and Siri language set to the same supported language (so a Hindi-UI phone is ineligible); 8 to 14 GB storage; not in China mainland. EU is supported.

## Fit for Bolkit
- English and en-IN transcripts: good fit for cleanup and summary. 8K context covers roughly 15 to 20 minutes of speech; longer needs chunking (inferred).
- Hindi and Hinglish: not supported by the LLM. Romanized Hinglish may partly work but is unsupported (inferred). Keep Gemma 4 E2B for Hindi, ineligible iPhones, and Android.
- PCC: better summaries and 32K, but leaves the device. Conflicts with the "private on-device" promise; skip or make an explicit opt-in.
- SpeechTranscriber `hi_IN` is worth benchmarking against Srota/Nemotron on Kumar's Hinglish set (free, no model download for the app).

## React Native exposure
Small Expo module (`expo-module-scripts`, Swift): `isAvailable()` returning the `availability` reason, `supportsLocale(tag)`, `cleanup(text)`, `summarize(text)` via `LanguageModelSession(instructions:)`. Stream with `streamResponse` through module events. In `src/asr/llm.ts`, pick Apple when available and the transcript locale is supported, else Gemma. Mac app: import FoundationModels directly with the same routing.

## Deployment target
iOS app stays at 16.4. Wrap every call in `if #available(iOS 26, *)` (27 for `variant`/`LanguageModel`), and ensure FoundationModels is weak-linked (Swift usually does this automatically when availability exceeds the target; verify with `otool -L`, inferred). `contextSize` back-deploys to 26.0 [SDK]. Build needs Xcode 26+ SDK. Mac app needs the same guards if its minimum is below 26.

## Privacy and review
- On-device model: no data leaves the device, no cost, no request limit [WWDC]. Privacy label unchanged.
- PCC: data sent to Apple servers (not stored) [WWDC]; disclose it if adopted.
- Guardrails can refuse on transcript content; handle `GenerationError.refusal` and fall back to Gemma (inferred as needed; refusal type confirmed [SDK]).
- Do not describe it as "Apple Intelligence" branding without following Apple's marketing guidelines (inferred).

## Next step
Enable Apple Intelligence on a device, rerun `probe.swift` for `contextSize`, and run 10 real English and Hinglish transcripts through both models.

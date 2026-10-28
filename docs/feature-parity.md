# Bolkit feature parity: Mac vs iOS

Read from source on 2026-09-18. Mac = `mac/Sources/Scribe/*.swift` (SwiftUI menu-bar app,
`mac/Info.plist:14` -> 1.3.1). iOS = `App.tsx` + `src/**` + `ios/**` (Expo/React Native,
`ios/Scribe/Info.plist:22,47` -> 1.0.0 build 9; `app.json` separately claims 1.2.0).

Paths are relative to the repo root. "No" means no implementation was found under any
obvious name.

| Feature | Mac | iOS | evidence (file:line) |
|---|---|---|---|
| **Live dictation** (streaming partial text) | Yes | Yes | Mac `mac/Sources/Scribe/DictationManager.swift:111` `start()`; iOS `src/asr/system.ts:62` `startLive`, `src/asr/live/whisperChunks.ts:22` `startWhisperChunks`, `src/asr/live/sherpaLive.ts:17` `startSherpaLive` |
| **Push-to-talk hold key** (fn / right-modifier, global) | Yes | No | Mac `mac/Sources/Scribe/SystemBridge.swift:47` `HoldKeyMonitor`, wired `mac/Sources/Scribe/ScribeApp.swift:65-83`, key choice `mac/Sources/Scribe/Settings.swift:4` `HoldKey`; iOS: no `HoldKey`/`hotkey`/`push-to-talk` symbol anywhere in `App.tsx`, `src/`, `ios/Scribe/` |
| **Global toggle hotkey** (ctrl-opt-space etc.) | Yes | No | Mac `mac/Sources/Scribe/SystemBridge.swift:8` `HotKeyManager`, `mac/Sources/Scribe/Settings.swift:315` `setToggle`; iOS: none |
| **Tap-to-toggle hands-free** | Yes | Yes (in-app button) | Mac `mac/Sources/Scribe/Settings.swift:177` `tapHandsFree`, `mac/Sources/Scribe/ScribeApp.swift:76-82`; iOS `src/ui/RecordButton.tsx:1` |
| **Types straight into the focused app** (any app, system-wide) | Yes | No | Mac `mac/Sources/Scribe/SystemBridge.swift:90` `Paster`, `:105` `insert`, `:163` `writeDirectly` (AX direct write, paste fallback); iOS keeps text in-app, clipboard/share only (`App.tsx:1046`, `App.tsx:1053`) |
| **Learns from your corrections after insertion** | Yes | No | Mac `mac/Sources/Scribe/CorrectionWatcher.swift:7`, toggle `mac/Sources/Scribe/Settings.swift:193` `learnCorrections`; iOS: no `correction`/`learnCorrection` symbol |
| **Always-on background surface** (menu-bar item) | Yes | No | Mac `mac/Sources/Scribe/ScribeApp.swift:33` `MenuBarExtra`; iOS is a foreground app |
| **Recording HUD overlay / notch HUD** | Yes | In-app waveform only | Mac `mac/Sources/Scribe/HUD.swift:1`, `mac/Sources/Scribe/NotchHUD.swift:6`; iOS `src/ui/Waveform.tsx:1` |
| **File import + transcription** | Yes | Yes | Mac `mac/Sources/Scribe/AudioImport.swift:12` `present()`, `:25` `run(url:)`, `:130` `decode`; iOS `App.tsx:741` `onImportFile`, `App.tsx:745` `DocumentPicker.getDocumentAsync` |
| **Compressed audio decode (mp3/m4a/aac)** | Yes (AVFoundation) | Yes (bundled ffmpeg) | Mac `mac/Sources/Scribe/AudioImport.swift:130`; iOS `App.tsx:791` `convertAudioToWav16k` |
| **Long-form record-then-transcribe mode** | Yes (meeting recorder) | Yes (Record Mode, mic only) | Mac `mac/Sources/Scribe/MeetingRecorder.swift:6`; iOS `src/ui/RecordScreen.tsx:81`, `src/audio/fileRecorder.ts:3` |
| **Meeting recording with system audio** (captures the other side of a call) | Yes | No | Mac `mac/Sources/Scribe/MeetingAudio.swift:79` `SystemAudioTap`, `:94` `CATapDescription(stereoGlobalTapButExcludeProcesses:)`, `:99` `AudioHardwareCreateProcessTap`, gated to macOS 14.4 at `mac/Sources/Scribe/MeetingRecorder.swift:9`; iOS: no `AudioTap`/`ScreenCapture`/`ReplayKit`/`system audio` reference in `App.tsx`, `src/`, `ios/Scribe/` |
| **Two-track You/Others transcript without diarization** | Yes | No | Mac `mac/Sources/Scribe/MeetingRecorder.swift:4-5` (you.caf + others.caf), `mac/Sources/Scribe/MeetingPipeline.swift:76` `you = 0` |
| ASR engine: Apple legacy `SFSpeechRecognizer` | Yes | Yes | Mac `mac/Sources/Scribe/DictationManager.swift:453` `beginLegacyApple`; iOS `src/asr/system.ts:62` (via `expo-speech-recognition`) |
| ASR engine: Apple `SpeechAnalyzer` / `SpeechTranscriber` (long-form) | Yes | No | Mac `mac/Sources/Scribe/ModernSpeechEngine.swift:28` `SpeechAnalyzer`, `:208` `AppleLongForm`; iOS has no `SpeechAnalyzer` reference in `ios/Scribe/`, deployment target 16.4 (`app.json`, expo-build-properties) |
| ASR engine: whisper.cpp | Yes | Yes | Mac `mac/Sources/Scribe/DictationManager.swift:724` `beginWhisperCpp`, batch via bundled `whisper-cli` helper `mac/Sources/Scribe/NativeTranscriptionWorker.swift:239-251`; iOS `src/asr/whisperEngine.ts:10` `WhisperEngine` (whisper.rn) |
| ASR engine: sherpa-onnx offline (Moonshine, Parakeet CTC/TDT, Canary, Whisper-ONNX, Dolphin) | Yes | Partly | Mac `mac/Sources/Scribe/SherpaEngine.swift:7`, catalog `mac/Sources/Scribe/ModelCatalog.swift:184-252`; iOS has Parakeet/Canary via direct k2-fsa archives `src/asr/nemo.ts:31`, but no Moonshine/Whisper-ONNX/Dolphin: `src/asr/catalog.ts:125-127` deliberately drops the sherpa catalog path and `src/asr/sherpa.ts:25` is unreachable (upstream release 404s) |
| ASR engine: sherpa-onnx streaming (Zipformer, Nemotron 3.5) | Yes | Yes | Mac `mac/Sources/Scribe/ModelCatalog.swift:254-273`; iOS `src/asr/nemo.ts:37-66` |
| ASR engine: FluidAudio Parakeet on the Neural Engine | Yes | No | Mac `mac/Sources/Scribe/FluidEngine.swift:7` `actor FluidEngine`, catalog `mac/Sources/Scribe/ModelCatalog.swift:286,292`; iOS: no FluidAudio dependency in `package.json` |
| ASR engine: Audio8 ARK 0.6B / Audio8-ASR 0.1B (raw ONNX Runtime) | Yes | No | Mac `mac/Sources/Scribe/ArkEngine.swift:11`, `mac/Sources/Scribe/ArkasrEngine.swift:12`, `mac/Sources/Scribe/Ort.swift:7`, catalog `mac/Sources/Scribe/ModelCatalog.swift:298,316`; iOS: no equivalent |
| ASR engine: audio-LLM ASR (Srota Hinglish, Gemma 4 E2B audio) | Yes | No | Mac `mac/Sources/Scribe/DictationManager.swift:645` `beginQwen`, `mac/Sources/Scribe/AsrRuntime.swift:7`, catalog `mac/Sources/Scribe/ModelCatalog.swift:172,275`; iOS `src/asr/llm.ts:5-7` states the LLM is post-processing only, never a transcription engine |
| ASR engine: MLX (Apple-silicon GPU) | Yes | No | Mac `mac/Sources/Scribe/MLXRuntime.swift:88`, `mac/Package.swift:50-53`; iOS: MLX not available |
| ASR engine: cloud BYOK (OpenAI-compatible) | No | Yes | iOS `src/asr/cloud.ts:13` `transcribeCloud`, `src/asr/catalog.ts:117`; Mac: no `apiKey`/BYOK symbol in `mac/Sources/Scribe/*.swift` |
| "Auto" model that resolves to the best installed | Yes | No | Mac `mac/Sources/Scribe/ModelCatalog.swift:436` `resolveAuto`; iOS stores one model id (`src/asr/settings.ts:22`) |
| **Speaker diarization** | Yes (two backends) | Yes (one backend) | Mac `mac/Sources/Scribe/SherpaDiarization.swift:19` `Diarizer` (pyannote + campplus) and `mac/Sources/Scribe/FluidEngine.swift:44` `SortformerMeeting`, picked at `mac/Sources/Scribe/MeetingPipeline.swift:109-113`; iOS `src/asr/diarize.ts:22` `ScribeDiarizer` + `ios/Scribe/ScribeDiarizer.swift` (pyannote + campplus only) |
| **Rename / merge speakers in the transcript** | Yes | No | Mac `mac/Sources/Scribe/SpeakerTranscript.swift:17` `rename`, `:19` `merge`; iOS renders fixed `Speaker N` labels (`src/asr/diarize.ts:202` `speakerLabel`) |
| **Auto-detects speaker names from the transcript** | Yes | No | Mac `mac/Sources/Scribe/MeetingPipeline.swift:163-164` `nameSpeakers`; iOS: none |
| **AI cleanup (local LLM rewrite)** | Yes | Yes | Mac `mac/Sources/Scribe/LLMEngine.swift:28` `LLMRuntime` (llama.cpp GGUF); iOS `src/asr/llm.ts:177` `cleanupWithLLM` (llama.rn, Gemma 4 E2B) |
| Cleanup runs automatically on every dictation | Yes | No | Mac `mac/Sources/Scribe/Settings.swift:242` `autoCleanLLM`, applied `mac/Sources/Scribe/DictationManager.swift:1345`; iOS is a manual button only, `App.tsx:694-713` |
| Cleanup output safety validator (rejects a bad rewrite) | Yes | No | Mac `mac/Sources/Scribe/TranscriptionSafety.swift:42` `TranscriptCleanupValidator`, used `mac/Sources/Scribe/DictationManager.swift:1358`; iOS returns the model output verbatim, `src/asr/llm.ts:145` |
| Cleanup backend: Ollama (local server) | Yes | No | Mac `mac/Sources/Scribe/OllamaRuntime.swift:9`, settings `mac/Sources/Scribe/Settings.swift:253-258`; iOS: no `ollama` reference |
| Cleanup/summary backend: Apple FoundationModels | Yes | No | Mac `mac/Sources/Scribe/MeetingPipeline.swift:9-15` `MeetingLLM.appleAvailable`, `:45` `run`; iOS: no `FoundationModels` reference |
| Cleanup backend: MLX | Yes | No | Mac `mac/Sources/Scribe/MLXRuntime.swift:88`, `mac/Sources/Scribe/ModelCatalog.swift:448` `cleanupModels`; iOS: none |
| **Summarization (LLM)** | Yes, meetings only | Yes, any transcript | Mac `mac/Sources/Scribe/LLMEngine.swift:52` `summaryInstruction`, invoked only from `mac/Sources/Scribe/MeetingPipeline.swift:166`; iOS `src/asr/llm.ts:185` `summarizeWithLLM` called from `App.tsx:715` |
| Summarization fallback with no model downloaded | No | Yes (extractive) | iOS `src/util/summarize.ts:38` `summarize`, fallback at `App.tsx:732`; Mac has no extractive summarizer |
| **Translation** | No | Yes | iOS `src/asr/translate.ts:72` `translateText` (ML Kit, 50+ on-device targets) plus the whisper translate flag `src/asr/whisperEngine.ts:50`; Mac: no translation symbol anywhere in `mac/Sources/Scribe/*.swift` |
| **Vocabulary / custom words** | Yes | Yes | Mac `mac/Sources/Scribe/Vocabulary.swift:5` (hotwords file for sherpa `:34`, whisper prompt `:51`, LLM hotwords `mac/Sources/Scribe/LLMEngine.swift:45`), setting `mac/Sources/Scribe/Settings.swift:190`; iOS `src/asr/vocab.ts:17` `mergeVocab` feeding whisper prompt `src/asr/whisperEngine.ts:52` and `contextualStrings` `src/asr/system.ts:78`, UI `src/ui/SettingsModal.tsx:252` |
| **Spoken punctuation** ("comma", "full stop") | Yes | Yes | Mac `mac/Sources/Scribe/VoiceCommands.swift:33` `punctuationWords`; iOS `src/util/polish.ts:6` `COMMANDS` |
| Voice commands: numbered lists ("point three") | Yes | No | Mac `mac/Sources/Scribe/VoiceCommands.swift:130`; iOS only has a flat `numbered list` to `1. ` replacement, `src/util/polish.ts:10` |
| Voice commands: destructive edits ("scratch that", "delete last word") | Yes | Yes | Mac `mac/Sources/Scribe/VoiceCommands.swift:108-127`; iOS `src/util/polish.ts:34-53` |
| Destructive edits suppressed for imported recordings | Yes | Yes | Mac `mac/Sources/Scribe/VoiceCommands.swift:67` `allowDestructive`; iOS `src/util/polish.ts:31-33` (`applyVoiceCommands` only runs on live text) |
| **Punctuation restoration for CTC/streaming engines** | Yes | Yes | Mac `mac/Sources/Scribe/SherpaPunctuation.swift:7` `PunctuationRuntime`, download `mac/Sources/Scribe/SupportModelStore.swift:76`; iOS `src/asr/punctuate.ts:121` + `ios/Scribe/ScribePunctuator.swift` |
| **Devanagari to Latin Hinglish romanization** | Yes | No | Mac `mac/Sources/Scribe/Romanizer.swift:7`, applied `mac/Sources/Scribe/DictationManager.swift:1331`, plus a dedicated `system-hinglish` model `mac/Sources/Scribe/ModelCatalog.swift:137`; iOS has no romanizer and depends on the Oriserve checkpoints emitting Latin already (`src/asr/registry.ts:14`) |
| **Model download / delete / cancel** | Yes | Yes | Mac `mac/Sources/Scribe/ModelStore.swift:93` `download`, `:123` `cancel`, `:129` `delete`; iOS `src/ui/ModelsModal.tsx:97,114,120`, `src/asr/modelManager.ts:1` |
| SHA-256 verification of downloads | Yes | No | Mac `mac/Sources/Scribe/ModelStore.swift:249` `sha256`, hashes at `mac/Sources/Scribe/ModelCatalog.swift:149,159`; iOS uses a 1% size tolerance only, `src/asr/llm.ts:46` |
| Multi-file model bundles (ONNX + external data, MLX safetensors) | Yes | No | Mac `mac/Sources/Scribe/ModelCatalog.swift:31` `BundleFile`, `mac/Sources/Scribe/ModelStore.swift:113` `startBundleFile`; iOS downloads one archive or file per model |
| Support-model downloads (punctuation, diarization) | Yes | Yes | Mac `mac/Sources/Scribe/SupportModelStore.swift:76,82`; iOS `src/asr/punctuate.ts:74`, `src/asr/diarize.ts:87` |
| **History / local storage** | Yes (50 items, text only) | Yes (200 items, richer) | Mac `mac/Sources/Scribe/DictationManager.swift:39` (UserDefaults), cap `:1377`, UI `mac/Sources/Scribe/Dashboard.swift:201`; iOS `src/history.ts:12,18` (JSON, language + translation metadata, edit/delete/clear), UI `src/ui/HistoryModal.tsx:1` |
| Edit a saved transcript in place | No | Yes | iOS `src/history.ts:48` `updateHistory`; Mac history is read-only in `mac/Sources/Scribe/Dashboard.swift:201` |
| **Meeting transcripts persisted as files on disk** | Yes | No | Mac `mac/Sources/Scribe/MeetingDetailView.swift:70-72` (`transcript.txt`, `summary.txt`), `mac/Sources/Scribe/MeetingRecorder.swift:14` |
| **Copy to clipboard** | Yes | Yes | Mac `mac/Sources/Scribe/ScribeApp.swift:108-119`, `mac/Sources/Scribe/MeetingDetailView.swift:197`; iOS `App.tsx:1046`, `src/ui/RecordScreen.tsx:410` |
| **System share sheet** | No | Yes | iOS `App.tsx:1053`, `src/ui/RecordScreen.tsx:413`, `src/ui/HistoryModal.tsx:105`; Mac has no `NSSharingService`/`NSSavePanel` |
| **Home-screen / lock-screen widget** | No | Yes | iOS `ios/ScribeWidget/ScribeWidget.swift:47`, embedded at `ios/Scribe.xcodeproj/project.pbxproj:47`; Mac uses the menu bar instead |
| **Keyboard extension (voice keyboard)** | n/a | Built, not shipped | iOS `ios/ScribeKeyboard/KeyboardViewController.swift:10` exists and is a native target (`ios/Scribe.xcodeproj/project.pbxproj:241`), but `ScribeKeyboard.appex` is absent from the app's Embed App Extensions phase (`ios/Scribe.xcodeproj/project.pbxproj:42-51`) and the app's only target dependency is ScribeWidget (`:568-573`), so it never reaches the built `.app` |
| **Home-screen quick actions** | No | Yes | iOS `src/quickActions.ts:24` `registerQuickActions` |
| **Floating overlay that types into other apps** | Yes (native paste) | Android only | Mac `mac/Sources/Scribe/SystemBridge.swift:105`; iOS `src/flowBubble.ts:5,17` gates the whole surface to Android |
| **Onboarding / setup guide** | Yes | Yes | Mac `mac/Sources/Scribe/Onboarding.swift:45`; iOS `src/ui/Onboarding.tsx:1` |
| **Auto-update in-app** | Yes (Sparkle) | No (App Store) | Mac `mac/Sources/Scribe/ScribeApp.swift:7` `UpdateManager`, `mac/Package.swift:19` |
| **Keeps the last recording for retry / diagnostics** | Yes | No | Mac `mac/Sources/Scribe/NativeTranscriptionWorker.swift:574` `DiagnosticAudioStore`, menu item `mac/Sources/Scribe/ScribeApp.swift:145-149`, setting `mac/Sources/Scribe/Settings.swift:186` |
| **Headless CLI + self-test harness** | Yes | Partial (unit tests only) | Mac `mac/Sources/Scribe/DebugCLI.swift:16` `runIfRequested` (`--transcribe`, `--selftest-commands`, ...); iOS has `src/asr/live/pauseChunker.test.ts`, `src/asr/vocab.test.ts`, `src/asr/whisperText.test.ts` but no runtime CLI |
| **GPU/CoreML execution-provider toggle** | Yes | No | Mac `mac/Sources/Scribe/Settings.swift:213` `useGpu`, `:238` `sherpaProvider(for:)`; iOS whisper.rn tries GPU then falls back automatically (`src/asr/whisperEngine.ts:25-29`) with no user control |
| **Restore clipboard after inserting** | Yes | n/a | Mac `mac/Sources/Scribe/Settings.swift:180`, `mac/Sources/Scribe/Dashboard.swift:853` |

## What the Mac has that iOS does not

1. Push-to-talk hold key and a global toggle hotkey.
2. Insertion straight into whatever app is focused, plus clipboard restore and correction learning off the inserted text.
3. An always-resident menu-bar surface and the recording HUD / notch HUD.
4. Meeting recording that captures system audio (the other side of a call) as a second track.
5. Speaker rename/merge and LLM-derived speaker names.
6. A second diarization backend (Sortformer on the ANE).
7. ASR engines: Apple `SpeechAnalyzer` long-form, FluidAudio Parakeet ANE, Audio8 ARK / Audio8-ASR ONNX, audio-LLM ASR (Srota, Gemma 4 audio), MLX, sherpa Moonshine / Whisper-ONNX / Dolphin, and the "Auto" resolver.
8. Automatic AI cleanup on every dictation, with an output-safety validator, and three extra cleanup backends (Ollama, Apple FoundationModels, MLX).
9. Devanagari to Latin romanization.
10. SHA-256 download verification and multi-file model bundles.
11. Meeting transcripts written to disk as `transcript.txt` / `summary.txt`.
12. Keep-last-recording and "retry last recording".
13. A headless CLI and a self-test harness.
14. In-app auto-update (Sparkle).
15. A user-facing GPU/CoreML provider toggle.
16. Numbered-list voice commands ("point three").

## What iOS has that the Mac does not

Translation (ML Kit, 50+ on-device targets), cloud BYOK transcription, an extractive
summarizer that needs no model, editable history with 200 items and language metadata,
the system share sheet, a home-screen widget, and quick actions.

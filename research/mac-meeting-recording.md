# Scribe Mac: "Record meeting" (system audio + mic)

Researched 2026-09-15 against the Xcode 27.0 macOS SDK. [C] = confirmed (SDK header or Apple doc), [I] = inferred, needs a device test.

## Recommendation: Core Audio process tap, not ScreenCaptureKit

SDK declarations [C]:

```
AudioHardwareCreateProcessTap(CATapDescription*, AudioObjectID*)  API_AVAILABLE(macos(14.2))
AudioHardwareDestroyProcessTap(AudioObjectID)                     API_AVAILABLE(macos(14.2))
- initStereoGlobalTapButExcludeProcesses:(NSArray<NSNumber*>*)    (CATapDescription, class macos(12.0))
@property privateTap; muteBehavior (CATapMuteBehavior, macos(13.0)); bundleIDs, processRestoreEnabled macos(26.0)
kAudioAggregateDeviceTapListKey "taps", kAudioSubTapUIDKey "uid", kAudioSubTapDriftCompensationKey "drift",
kAudioAggregateDeviceIsPrivateKey "private", kAudioTapPropertyFormat 'tfmt'

SCStreamConfiguration.capturesAudio      macos(13.0)
SCStreamConfiguration.captureMicrophone  macos(15.0)   (+ microphoneCaptureDeviceID, SCStreamOutputTypeMicrophone)
```

Why the tap:
- Permission is audio-only. Apple's doc: include `NSAudioCaptureUsageDescription` in Info.plist; the first time you start an aggregate device containing a tap, the system prompts for "system audio recording permission" [C, developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps]. ScreenCaptureKit instead lands in "Screen & System Audio Recording" and, per developer forum reports, Sequoia adds a recurring "bypass the private window picker" re-prompt [forum reports, not Apple docs].
- No dummy video stream, no SCShareableContent round-trip.
- Min macOS: header says 14.2; the AudioCap sample (insidegui/AudioCap) says 14.4. Unresolved which is the real floor, so gate the UI with `#available(macOS 14.4, *)`; Scribe's LSMinimumSystemVersion stays 14.0 [I].
- No public API to preflight or request the permission; the prompt fires on first start [C, AudioCap README]. Treat a silent (all-zero) system track after 2 s as "permission denied" and link to System Settings [I].
- (Recall.ai's blog claims SCK mic capture needs "macOS 16+"; the SDK header says 15.0. Header wins.)

## Two tracks

One private aggregate device: default input device as sub-device, plus a `CATapDescription(stereoGlobalTapButExcludeProcesses: [scribePid])` tap with `privateTap = true`, `muteBehavior = .unmuted`, `"drift": 1` on the tap. One `AudioDeviceCreateIOProcIDWithBlock` callback receives mic and tap buffers on a shared clock, so drift is handled by the HAL [key names C, behaviour I]. Fallback if the combo misbehaves: tap-only aggregate plus a separate AVAudioEngine mic, store both first-buffer host times in `meta.json`; ~50 ppm drift is ~0.2 s/hour, fine for transcript interleaving [I].

Format: downmix each side to mono, `AVAudioConverter` to 16 kHz (`TranscriptionLimits.sampleRate`), write Int16 PCM `.caf` via `AVAudioFile`. CAF stays readable after a crash; m4a does not until closed [I]. Write off the IO thread (ring buffer to a serial queue).

Echo without headphones: the raw mic hears the speakers, so "You" will contain "Others". Zoom/Meet AEC only cleans their own uplink, not our tap. v1: show "Use headphones for clean speaker labels" hint; at merge, drop a mic segment whose text heavily overlaps a system segment within +/-1 s. Voice-processing AEC on the mic (`setVoiceProcessingEnabled`) is worth one test but unverified against other apps' output [I].

## Developer ID

Tap needs only the Info.plist key; Apple's doc lists no entitlement [C]. Scribe is not sandboxed, so direct distribution with hardened runtime + notarization should work unchanged [I, verify on a notarized build]. TCC grants key on code signature: ad-hoc rebuilds will re-prompt (see existing /Applications install gotcha) [I].

## Implementation plan

New files (Sources/Scribe):
1. `SystemAudioTap.swift` (~180 lines): tap + aggregate device create/destroy, IOProc, two `AVAudioFile` writers.
2. `MeetingRecorder.swift` (~150 lines): `ObservableObject` singleton, `isRecording`, elapsed time, start/stop, folder + `meta.json`, then transcription hand-off.

Touch:
- `Info.plist`: add `NSAudioCaptureUsageDescription` ("Scribe records meeting audio from other apps on this Mac to transcribe it on-device.").
- `ScribeApp.swift` `MenuContent`: "Record meeting" / "Stop meeting (12:34)" button under dictation.
- `DictationManager.swift`: refuse dictation while a meeting records (mirror the `AudioImport.run` guard), avoids two engines on one mic.
- `HUD.swift`: red dot + timer variant of the pill.
- `Dashboard.swift`: same toggle plus "Show recordings in Finder". Transcripts reach history via existing `DictationManager.importedResult`.
- `AudioImport.swift`: expose `decode` and `presentSpeakers`; add `transcribeTracks(you:others:)`: split each track with the existing `SileroVAD` (SherpaEngine.swift) into timed segments, run `NativeTranscriptionWorker.shared.transcribe` per segment, build `SpeakerTurn(speaker: "You"/"Others")`, sort by start, `clean()`, `presentSpeakers`. Segmenting also keeps long meetings inside worker timeouts. Existing sherpa diarization can later split "Others" into Speaker 1/2.

Storage: `~/Library/Application Support/Scribe/Meetings/2026-09-15_1430/{you.caf, others.caf, meta.json, transcript.txt}` (same base as `ModelStore`).

## Size

16 kHz mono Int16 = 32 KB/s = ~115 MB/hour per track, ~230 MB/hour total. Optional post-transcribe AAC 32 kbps transcode drops that to ~30 MB/hour. Code: ~350 new lines + ~80 lines of edits.

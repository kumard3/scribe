# Scribe, App Store listing copy

Bundle id `ai.localvoice.app` · Team Q84L632A4A · Category: Productivity · Age 4+

## App Name (30 max)

**In use: `Scribe: Talk to Type` (20)**

Plain `Scribe` is rejected by App Store Connect, already in use by someone else.
Bare dictionary words are almost always reserved; distinctive phrases are not.
The home screen name is unaffected and stays `Scribe` (CFBundleDisplayName).

## Subtitle (30 max)

`On-device speech to text` (24)

## Promotional text (170 max)

Dictation that runs entirely on your iPhone. No account, no subscription, no
audio leaving the device. Pick your model, speak, and get text back.

## Keywords (100 max, comma separated, no spaces)

```
dictation,speech,transcribe,voice,typing,offline,private,whisper,hindi,hinglish,notes,stt,transcription
```

## Description

Scribe turns speech into text entirely on your iPhone. Nothing is uploaded,
nothing is logged, and there is no account to create.

Most dictation apps stream your voice to a server. Scribe does not. The speech
models run locally, so it works on a plane, in a basement, or with the network
off, and your audio stays where you said it.

FREE, WITH NO CATCH
There is no subscription, no usage cap, no API key, and no paid tier. Scribe is
open source under the MIT license.

CHOOSE YOUR MODEL
Download only the models you want, each labelled by size and accuracy: Whisper,
Parakeet, Moonshine, Canary, Dolphin, and Srota. Small models are fast and light.
Larger ones are more accurate. Swap between them any time. Models load on demand
and unload after five minutes idle, so Scribe stays light on memory.

HINGLISH THAT LOOKS RIGHT
Hindi speech comes back in English letters, the way people actually type it, not
in Devanagari you then have to convert. Toggle it off if you want the script.

SPOKEN COMMANDS
Say "next line", "new paragraph", "point one" to number a list, "bullet" for
dashes, or "scratch that" to drop the last line.

IMPORT AUDIO
Bring in an existing m4a or mp3 and get a transcript, with punctuation restored.

OPTIONAL AI CLEANUP
An optional on-device Gemma model tidies filler words and can summarise what you
said. Like everything else here, it runs locally.

KEYBOARD
The Scribe keyboard lets you dictate from inside other apps. iOS does not permit
keyboard extensions to use the microphone, so tapping Dictate opens Scribe to
record, then you return and tap Paste to insert the text.

PRIVACY
No telemetry. No analytics. No accounts. The only network requests Scribe ever
makes are downloading the speech models you choose.

## What's New (version 1.0.0)

First public iOS release.

## Review notes (for App Review, not public)

- No account required, so no demo credentials are needed.
- On first launch the app downloads a speech model. Please allow it to finish
  before testing dictation; on wifi this is under a minute for the default model.
- The keyboard extension requests Full Access solely to read the clipboard so it
  can insert a transcript produced by the main app. iOS blocks microphone access
  in keyboard extensions, so the main app does the recording. No data is sent off
  device by the keyboard or the app.
- Source: https://github.com/kumard3/scribe

## URLs

- Support: https://github.com/kumard3/scribe/issues
- Marketing: https://scribe-site.kumard3.workers.dev
- Privacy: https://scribe-site.kumard3.workers.dev/privacy

## App Privacy answers

Data collected: **None**. No tracking. No data linked to the user.

## Finishing the submission

A signed App Store IPA already builds from a clean checkout. Rebuild it with:

```bash
S=/tmp/scribe-release
xcodebuild -workspace ios/Scribe.xcworkspace -scheme Scribe -configuration Release \
  -destination 'generic/platform=iOS' -archivePath $S/Scribe.xcarchive \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=Q84L632A4A CODE_SIGN_STYLE=Automatic archive
xcodebuild -exportArchive -archivePath $S/Scribe.xcarchive \
  -exportOptionsPlist ExportOptions.plist -exportPath $S/export -allowProvisioningUpdates
```

Upload needs an App Store Connect API key, which is the only piece that cannot be
produced from this machine. Create one at App Store Connect → Users and Access →
Integrations → App Store Connect API, role **App Manager**. Put the `.p8` at
`~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8`, then:

```bash
xcrun altool --validate-app -f $S/export/Scribe.ipa -t ios \
  --apiKey <KEYID> --apiIssuer <ISSUERID>
xcrun altool --upload-app  -f $S/export/Scribe.ipa -t ios \
  --apiKey <KEYID> --apiIssuer <ISSUERID>
```

## Status

Fixed:

- Permission prompts said "Vox" on an app named Scribe. `ios/Vox/Info.plist` had
  drifted from `app.json`; both now say Scribe.
- `ITSAppUsesNonExemptEncryption` was missing, so App Store Connect prompted on
  every upload. Added to `Info.plist` and `app.json`.
- iPad support removed (`TARGETED_DEVICE_FAMILY = 1`, `supportsTablet: false`).
  No iPad screenshots needed and review will not test an undesigned iPad layout.
  Reverse both if iPad is ever wanted.
- `llama.rn` binaries were never fetched because bun skips untrusted postinstall.
  `trustedDependencies` added so a clean clone builds.

- Whole project renamed Vox to Scribe: targets, project, workspace, scheme,
  folders, extension bundle ids, and the `vox://` URL scheme (now `scribe://`,
  changed in all four places that must agree, including `App.tsx`).
- Apple Distribution certificate created via Xcode > Settings > Apple Accounts >
  Manage Certificates. It was absent entirely, which was the export blocker.

Blocked on something only Kumar can supply:

- **Device testing.** Nothing has ever executed on a real iPhone. Biggest ship
  risk, review rejects on first crash. Builds are on TestFlight, so this no
  longer needs a cable. The app DID run correctly end to end in the simulator.
- **Submit for Review.** Needs the App Store Connect web UI or a `.p8` API key.
  Xcode can only upload builds, not set metadata or submit.

Won't fix, with reasons:

- **Simulator needs ML Kit unlinked** (SOLVED, see Screenshots). Google ML Kit
  ships its arm64 slice built for `platform IOS`, not IOSSIMULATOR, so CocoaPods
  sets `EXCLUDED_ARCHS[sdk=iphonesimulator*] = arm64` and the app cannot run on an
  Apple Silicon simulator. No version bump fixes it, but a temporary
  `react-native.config.js` that nulls out the two ML Kit packages on iOS removes
  the pods, drops the exclusion, and the app runs. `translate.ts` already guards on
  `NativeModules.TranslateText != null`, so nothing crashes.
- **Nemotron on iOS.** `react-native-sherpa-onnx@0.4.3` is the newest release and
  pins sherpa-onnx 1.12.34-2; the Mac app uses 1.13.3. Forcing a newer binary
  risks an ABI mismatch that cannot be verified without a simulator or a device.
  Six other models work.
- **Keyboard Full Access.** It uses the clipboard as an IPC channel because no App
  Group is registered, and registering one needs developer portal access. This is
  the largest guideline 4.4.1 risk in the submission.

## Submission log

2026-07-27: Build 1.0.0 (1) **uploaded to App Store Connect**. App record created
as **"Scribe: Talk to Type"** (plain "Scribe" was rejected, already in use). Home
screen name stays "Scribe" via CFBundleDisplayName.

Upload warnings were all "Upload Symbols Failed" for prebuilt binary frameworks
(React, ReactNativeDependencies, hermesvm, rnwhisper). These ship without dSYMs,
so crash reports from them will not symbolicate. Not a review blocker.

Still required before Submit for Review:
- Screenshots (6.9" iPhone). Must come from a physical device, see ML Kit note.
- Description, keywords, category, age rating, privacy answers (copy is above).
- Device testing. Install build 1 from TestFlight and confirm it launches.

## Screenshots

`marketing/screenshots/` holds 6 shots at 1320x2868 (6.9 inch, iPhone 17 Pro Max
simulator). Upload as-is, no resizing needed.

Captured from a build with the ML Kit pods temporarily unlinked via a throwaway
`react-native.config.js`, because Google ML Kit ships no arm64 iOS-simulator slice
and otherwise forces `EXCLUDED_ARCHS[sdk=iphonesimulator*] = arm64`, making the app
unrunnable on an Apple Silicon simulator. That file was deleted and pods reinstalled
afterwards; release builds are unaffected. Every screen shown is real and unmodified.

The Settings screen was deliberately EXCLUDED: in that build it reads "Translation
isn't available in this build", which is untrue of the shipping app.

## Build 2 (2026-07-28)

Uploaded to App Store Connect at 12:41. Fixes Apple's ITMS-90683 rejection of build 1.

- `NSPhotoLibraryUsageDescription` added. Required because `Scribe` and
  `ExpoFileSystem` reference `PHAsset` and the Photos framework is linked, even
  though the app never opens the photo library.
- Build number 2 on the app AND both extensions. Mismatched extension build numbers
  are their own rejection.
- Removed `NSLocalNetworkUsageDescription` and `NSBonjourServices` (`_expo._tcp`).
  The release binary links expo-dev-client, so users would have seen a local-network
  prompt reading "Expo Dev Launcher uses the local network to discover and connect to
  development servers on your computer" on a privacy-first app. Consider dropping
  expo-dev-client from production dependencies entirely.

Final permission set, each backed by a linked API: microphone, speech recognition,
photo library. `libswiftCoreLocation.dylib` is linked transitively but no
`CLLocationManager` usage exists, so no location string was added on purpose.

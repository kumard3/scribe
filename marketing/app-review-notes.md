# App Review reply, Guideline 2.1 Information Needed

Submission `362737bf-471a-4e11-8fcc-2299cb21b16f` · build 1.0.0 (2) · rejected 2026-08-14.

**This is not a bug rejection.** Apple found no crash and no broken feature. It
is the standard new-app "we need information" template: the App Review
Information > Notes field was thin, and since 2025 Apple asks every new app for
a demo screen recording. Nothing in the binary has to change. Reply with the
information below and the same build goes back into review.

**Only one thing here needs Kumar:** the screen recording. Everything else is
written and ready to paste.

## Status, 2026-08-16

Done in App Store Connect, saved and verified after a reload:

- App Review Information > Notes now holds the section 2 text (3778 chars).
  The old text, which wrongly told the reviewer to wait for a first-launch model
  download, is gone.
- The version Description's PRIVACY paragraph is replaced with the accurate
  wording (1902 chars).
- Release is Manual, sign-in-required is off. Neither was touched.

### Build 2 is no longer the build to ship (2026-08-17)

First device run found a real bug: Record mode with the language pill on
Auto-detect returned the literal string `[NON-ENGLISH SPEECH]` instead of a
transcript. Two stacked causes, both fixed in the repo, neither in build 2:

- `App.tsx` fell back to `whisper-small-en-q5` for Record mode regardless of the
  selected language. `.en` models have no language-detection head, so `'auto'`
  makes them emit an annotation token. The fallback is now language-aware.
- Nothing stripped Whisper's bracketed annotations, so `[BLANK_AUDIO]`,
  `[MUSIC]` and friends rendered as if they were the user's words. Now stripped
  in `whisperText.ts`, covered by `whisperText.test.ts` (`bun` it).

Build numbers bumped to 3 on the app and both extensions. Record the video
against build 3, not build 2; a reviewer who touches the language picker on
build 2 hits the same placeholder string and that is a genuine 2.1 bug
rejection, not an information request.

## Status, 2026-08-22

Done today, all verified through the App Store Connect API:

- **App Store Connect API access enabled and a key created.** Team key
  `scribe-ci`, role App Manager. Key ID `2S4W5QQ4T6`, Issuer
  `fc850c72-bbab-45db-adf4-d9278ca710ee`, private key at
  `~/.appstoreconnect/private_keys/AuthKey_2S4W5QQ4T6.p8` (Apple only serves the
  .p8 once, the `~/Downloads` copy is the only backup). `scripts/asc.py` wraps
  the REST API, so status checks and uploads no longer need a browser login.
- **Build 3 is attached to iOS version 1.0.** It was already uploaded on
  2026-08-17 and sitting VALID but unattached; the version still pointed at
  build 2. Now `appStoreVersions/1c01e7db.../build` resolves to build 3.
- **TestFlight internal group exists at last.** Group `Internal`
  (`560501df-e1d0-4379-978d-913de3105090`) holds build 3, with
  kumardeepanshu157200@gmail.com invited. kr.deepanshu@icloud.com CANNOT be
  added: internal testers must be App Store Connect users, and that Apple ID is
  not one. If the phone's TestFlight is on the icloud address, either sign
  TestFlight in as the gmail one, or invite the icloud address as an ASC user
  (Developer role) first.
- **A development-signed IPA is ready** at `/tmp/scribe-release/dev/Scribe.ipa`,
  re-exported from the same archive, for `xcrun devicectl device install app`
  the moment the iPhone is plugged in. It has been `unavailable` to devicectl
  all session.
- Review notes verified live in ASC: 3778 chars, demo account not required,
  contact phone `+918873630016`.

Two build-environment traps, both from `node_modules` having been wiped:

- The archive died in the Hermes `replace_hermes_version.js` phase because
  `node_modules` was empty. `bun install` fixes it.
- Then it died compiling `sherpa-onnx-tts-wrapper.mm`, missing
  `sherpa-onnx/c-api/cxx-api.h`. `react-native-sherpa-onnx` downloads its
  xcframework from a hook that runs when its **podspec** loads, so a wipe of
  `node_modules` without a following `pod install` leaves the headers gone while
  `Podfile.lock` still matches `Manifest.lock`. Fix without a full pod install:
  `SHERPA_ONNX_PROJECT_ROOT=$PWD bash scripts/setup-ios-framework.sh` inside
  `node_modules/react-native-sherpa-onnx`.

Check ASC for an existing build before rebuilding. The archive rebuilt here was
wasted work: build 3 was already up, and the duplicate upload was discarded by
ASC (no new build row appeared).

### Build 4: vocabulary bias and no iOS keyboard (2026-08-22, later)

Kumar's first device take found a second real bug and made a product call. Both
are in build 4, which supersedes build 3.

**"Scribe" transcribed as "Chris" on the default Apple engine.** The vocabulary
feature existed but never reached Apple's recognizer on either platform, and the
default vocabulary was empty, so nothing biased the product's own name.

- `src/asr/vocab.ts` is the one source of truth: `BASE_VOCAB = ['Scribe']` merged
  with the user's terms, deduped case-insensitively. `mergeVocab` is pure and
  covered by `src/asr/vocab.test.ts` (`bun` it).
- `settings.biasTerms()` replaces `getVocab()` at every engine call site.
- `App.tsx` also passes it on the `'end'` auto-restart, which previously dropped
  the bias mid-dictation even when the user had terms set.
- Mac: `Vocabulary.biasTerms` now feeds `SFSpeechAudioBufferRecognitionRequest.
  contextualStrings` in `DictationManager.startAppleTask` and the
  `AnalysisContext` of the macOS 26 `SpeechAnalyzer` in `ModernSpeechEngine`.
  Neither Apple path had ever seen the vocabulary. whisper prompt and sherpa
  hotwords now read from `biasTerms` too, so the base terms apply everywhere.

Not done: mobile sherpa hotwords. `react-native-sherpa-onnx` accepts a
`hotwordsFile`, but it only applies to transducer models and needs a
`modelingUnit`/`bpeVocab` pairing, so wiring it blind is a worse risk than the
gap. Whisper and the Apple engine, which is what the reviewer meets, are covered.

**The iOS keyboard is no longer shipped.** Kumar's call, the implementation is
poor: the clipboard-as-IPC handoff with Full Access and no App Group. This also
removes the largest guideline 4.4.1 risk from the submission.

- `ios/Scribe.xcodeproj`: the extension is out of the Embed App Extensions phase
  and out of the Scribe target's dependencies. The target and source stay in the
  repo; restore those two entries to re-embed it.
- The "Type anywhere" onboarding slide and the Settings "Voice keyboard" section
  are Android-only now. Android keeps its keyboard, it is a real IME with mic
  access.
- The App Store description's KEYBOARD paragraph and the review notes' keyboard
  step are already removed live in ASC (description 1902 to 1675 chars, notes
  3778 to 3353).

**Build numbers in ASC are the local plist value plus one.** The plists said 3
and the upload registered as build 4; bumped to 4 and the next upload registered
as build 5. Something in the Expo build phase increments it. Do not chase a
"missing" build after an upload, and do not assume a duplicate was rejected:
poll `/v1/builds` and read the number that actually lands. **ASC build 5**
(delivery `dfcb497b`, uploaded 17:25 IST) is the one carrying the vocabulary fix
and no keyboard, and it is attached to iOS version 1.0. The same binary is
installed on the iPhone.

Still not done, still blocked on the recording:

- Attach the video. There is a "Choose File (Optional)" slot directly under the
  Notes field in App Review Information, which is the tidiest place for it.
- Reply in App Review Communication with section 3.
- Click "Update Review" on the version page. Do not click it before the video
  exists; it resubmits, and a resubmit without the recording earns the identical
  2.1 rejection and another 24 to 48 hours.

## Status, 2026-09-07

The recording exists and is on the version. Kumar shot it on the iPhone on
2026-08-29 (`~/Downloads/ScreenRecording_08-29-2026 08-52-01_1.MP4`, 90 s,
HEVC 60 fps, silent audio track). It covers launch, the three onboarding
slides, the microphone prompt, the speech recognition prompt, live dictation,
a Record-tab capture, the model download to 100%, the Models sheet, History,
and pasting the transcript into Notes. Import and the History delete are not
in it, so the reply below does not claim them.

- Re-encoded to H.264 30 fps with the silent track dropped:
  `~/Downloads/scribe-ios-review-recording.mp4` (5.5 MB). Attached through the
  API as App Review attachment `98acd891-650b-4b0d-96c7-3499377b6b2c`, state
  UPLOAD_COMPLETE, and it shows under the Notes field in the version page.
- Notes TESTED ON line now says build 1.0.0 (5), the build attached to the
  version, instead of "TestFlight build 1.0.0 (2)". Patched through
  `appStoreReviewDetails/70b4370a...`.
- Reply posted in App Review Communication from BrowserOS neo (the
  section 3 text, adjusted to what the recording actually shows). Messages
  went from 1 to 2.

Resubmitted 2026-09-07 11:36 IST. Submission `362737bf` is WAITING_FOR_REVIEW
and iOS 1.0 is Waiting for Review (API-verified). It takes two clicks, in this
order: "Update Review" on the version page first (the version item flips to
Ready for Review inside the submission), and only then does "Resubmit to App
Review" on the submission page enable. Before that first click it stays
disabled no matter what you attach or reply. Release is Manual, so approval
still needs a Release click.

## Status, 2026-09-11

Rejected 2026-09-09 (reviewed on iPad Air 11" M3, build 1.0 (5)). The 2.1
request is closed; no functional issues. Two metadata items:

- **1.5 Safety:** a GitHub issues page is not an acceptable Support URL. Added
  `website/src/pages/support.astro` (contact email, FAQ), deployed, and set the
  Support URL on the iOS and Mac 1.0 listings to
  `https://scribe-site.kumard3.workers.dev/support`.
- **4.1(c) Copycats:** "the app's name contains a brand that belongs to the
  developer Scribe". At least six other "Scribe" apps exist, including "Scribe -
  Speech to Text" (Hive AI, on-device STT, 2020). Kumar chose to keep the name
  and contest it: the reply argues "scribe" is a descriptive common word used by
  many unrelated developers, asks which developer/trademark is meant, and says we
  rename if they hold a registered trademark.

Resubmitted 2026-09-11 02:20 IST, WAITING_FOR_REVIEW (API-verified). App Review
Board appeal filed the same night on 4.1 only (form at
https://developer.apple.com/contact/request/app-review/appeal/, topic App
Rejection, same argument in 1,416 chars); Apple confirmed receipt on screen. That
was the one appeal allowed for this submission. If the Board upholds 4.1(c), the
only path left is a rename: app.json `name` + permission strings and
`ios/Scribe*/Info.plist` CFBundleDisplayName, so it needs a new build.

---

## 1. The screen recording (Kumar, ~3 minutes)

**It cannot be automated from the Mac.** iPhone Mirroring drives the phone fine,
taps and onboarding and both permission prompts all work, but the moment
dictation starts iOS puts up `iPhone microphone is not available from Mac.`
Mirroring blocks mic capture outright, so every dictation take fails on camera.
Tested 2026-08-22, not assumed.

Record on the iPhone 17 Pro with iOS Screen Recording (Control Centre), then
attach the .mp4 to the App Review reply. Apple wants the file to start at app
launch, so start recording on the home screen.

Leave **Microphone OFF** in the Control Centre recorder (long press the record
button). With it on, the recorder and Scribe fight over the mic. The transcript
appearing on screen is the proof, the audio track is not needed.

Build 3 is already installed on the device (dev-signed, via devicectl) and was
reinstalled clean at 16:53 on 2026-08-22, so onboarding and both permission
prompts will replay on the next launch. Do not open it before recording.

Shot list, in order, no cuts:

1. Home screen, tap the Scribe icon. Let the onboarding play through.
2. The microphone permission prompt appears. Tap Allow. Then the speech
   recognition prompt. Tap Allow. Do not skip these, Apple asked to see them.
3. On the record screen, tap the big button, say two or three sentences, tap
   again. Show the transcript appearing.
4. Tap Copy, then open Notes and paste, so the output is visibly real.
5. Back in Scribe, open Models. Show the list. Tap "Sharper English", let the
   download bar run to done, then dictate once more with it selected.
6. Open History, show a saved item, delete it.
7. Open Settings, scroll the whole screen so the reviewer sees there is no
   account, no sign in, and no paid tier.
8. Import: tap the import control, pick any m4a, show the transcript.

Nothing to record for: account registration, login, account deletion, purchases,
subscriptions, user-generated content, App Tracking Transparency. The app has
none of them. Say so in the reply rather than leaving it unexplained.

---

## 2. Paste this into App Review Information > Notes

Keep it under the 4000 character field limit. It currently fits.

```
SCRIBE, REVIEW NOTES

NO ACCOUNT, NO PURCHASES
There is no sign up, no login, no account, and no account deletion flow,
because the app has no accounts and no backend. There is no in-app purchase,
subscription, or paid tier. No demo credentials are needed. The app is free and
open source under the MIT licence.

WHAT IT DOES AND WHO IT IS FOR
Scribe is a dictation app. You speak, it writes the text on the device. It is
for people who type a lot on a phone and would rather talk: students taking
notes, journalists, people writing long messages, and people whose first
language is not English.

The problem it solves: mainstream dictation apps stream your voice to a company
server and charge a monthly fee. Scribe runs the speech models locally, so it
works with the network off and the audio is not sent to us. We do not operate a
server, so there is nothing for us to receive.

HOW TO REACH THE MAIN FEATURES
1. Launch the app. Onboarding runs once, then the record screen opens.
2. Allow the microphone and speech recognition prompts.
3. Tap the large button, speak, tap again. The transcript appears and can be
   copied. No download is required for this, the default engine is the phone's
   built-in one.
4. Models: tap Models. Every entry other than the default is an optional
   one-time download of an offline speech model. Pick one and it downloads,
   then dictation runs fully offline.
5. Import: pick an existing m4a or mp3 and get a transcript.
6. History: past transcripts, stored only on the device, deletable.

EXTERNAL SERVICES USED
- Apple Speech framework (SFSpeechRecognizer). This is the default engine. It
  runs on device when the user's dictation language pack is installed; if it is
  not, iOS handles the request through Apple's speech service.
- Hugging Face (huggingface.co) and GitHub Releases (github.com/k2-fsa). Static
  file downloads only, for the optional offline speech models, punctuation and
  speaker models. No API key, no account, no data sent up.
- Google ML Kit on-device Translation, bundled. Downloads a language pack once
  from Google, then translates locally.
- Optional, off by default: the user may enter their own API key for any
  OpenAI-compatible transcription endpoint. Only then does audio leave the
  device, to the provider the user chose.

There is no authentication provider, no payment processor, no analytics, no
advertising SDK, no crash reporting, and no backend operated by us.

REGIONAL DIFFERENCES
None. The app behaves identically in every region. No geofenced features, no
region-specific content, no regional pricing (it is free with no in-app
purchases). Which languages transcribe well depends on the model the user
picks, not on where they are.

REGULATED INDUSTRY AND THIRD-PARTY MATERIAL
Scribe is not in a regulated industry. It is a productivity utility with no
health, financial, gambling, or medical functionality. All speech models are
publicly released open-weight models under MIT, Apache 2.0 or CC-BY licences
(OpenAI Whisper, MIT; NVIDIA NeMo via k2-fsa/sherpa-onnx, Apache 2.0/CC-BY;
Google Gemma, Gemma Terms of Use). The app's own source is MIT and public at
https://github.com/kumard3/scribe.

TESTED ON
iPhone 17 Pro (iPhone18,1), iOS 26.5.2 (build 23F84), via TestFlight build
1.0.0 (2). Minimum deployment target iOS 16.4. iPhone only, iPad is not
supported.
```

The iOS version came from the Mac's pairing record for the device, not from the
phone itself. Glance at Settings > General > About > Software Version before you
paste, and correct it if the phone has updated since. If you test on more than
one device, list each one, Apple asked for a list.

---

## 3. Reply message to App Review

Paste in the "Reply to App Review" box, attach the screen recording.

```
Thank you for the review. A screen recording captured on a physical iPhone 17
Pro is attached. It starts at app launch and walks through onboarding, the
microphone and speech recognition permission prompts, live dictation, copying
the result into another app, downloading an optional offline model, importing
an audio file, and the transcript history.

Scribe has no account registration, login, or account deletion flow, no in-app
purchases or subscriptions, no user-generated content shared between users, and
it does not use App Tracking Transparency, so none of those flows appear in the
recording. The only permission prompts the app raises are microphone, speech
recognition, and photo library (only when the user imports an audio file), and
all three are shown.

The full detail you asked for, covering the tested devices, the app's purpose
and audience, setup instructions, the external services it uses, regional
behaviour, and licensing of the speech models, is now in the Notes field of the
App Review Information section, and will stay there for future submissions.

Happy to provide anything further.

Kumar
```

---

## 4. Two things fixed in this repo while checking

Neither caused the rejection. Both would have been a real problem later.

- The review notes in `appstore-listing.md` told the reviewer to wait for a
  model download on first launch. That has been wrong since the default model
  became `system`, which downloads nothing. A reviewer following it would have
  sat waiting for something that never happens.
- The app and the store description claimed audio "never leaves your phone",
  without qualification. The default engine falls back to Apple's speech service
  when the user's on-device dictation language pack is not installed, so the
  claim was not true on that path. Guideline 5.1.1 and the App Privacy answers
  both hang on this being accurate. Wording corrected in `Onboarding.tsx`,
  `SettingsModal.tsx`, `PRIVACY.md` and `appstore-listing.md`.

  If you would rather keep the absolute claim than qualify it, the alternative
  is to force `requiresOnDeviceRecognition: true` in `src/asr/system.ts` and
  fail loudly when the pack is missing. That makes the claim true but breaks
  first-run dictation for anyone without the pack, which is a worse review
  outcome. Qualifying the wording was the safer call.

# Scribe — Production Readiness

Launch order: **Android first** (sideloadable + Play, no approval gate) → desktop
(Mac / Windows / Linux, all sideloadable) → **iOS last** (needs App Store review).

> The one blocker that gates everything: **nothing here has been run on a real
> device yet.** Every native feature is compile-verified only. Before any public
> build, run on a real Pixel + iPhone + a Windows PC and exercise every path.

---

## Android (launch target)

### Build for distribution
- **Play Store (recommended):** `cd android && ./gradlew :app:bundleRelease`
  → produces a signed `.aab`. Play generates per-device APKs, so the 4-ABI size
  is automatically split away — no config change needed.
- **Sideload APK (smallest):** build arm64 only (covers ~all modern phones):
  `./gradlew :app:assembleRelease -PreactNativeArchitectures=arm64-v8a`
  Add `armeabi-v7a` too if you need older 32-bit devices.

### Signing — DONE
`android/keystore.properties` + `android/app/vox-upload.jks` are present and wired
into the release build type. **Back this keystore up off-machine** — losing it
means you can never update the Play listing.

### Size / R8 minify — validate on device, THEN enable
R8 is currently **off**. Keep rules for the JNI libs (sherpa, whisper, ML Kit, our
native modules) are already in `proguard-rules.pro`. To enable after you've
confirmed a release build runs on a device:
```
# android/gradle.properties
android.enableMinifyInReleaseBuilds=true
android.enableShrinkResourcesInReleaseBuilds=true
```
Then **re-test on device** — R8 stripping causes release-only crashes that don't
show in debug. The bigger size win is ABI handling (above); R8 mostly trims
Java/Kotlin, which is a small slice of an RN app.

### Play Console requirements
- [ ] Privacy policy URL (host `PRIVACY.md` — GitHub Pages works) — **required**.
- [ ] Data safety form: declare "no data collected/shared" (true unless the user
      enables BYOK cloud). Mention on-device processing.
- [ ] Store listing (see `STORE_LISTING` section below): title, short + full
      description, feature graphic, ≥2 phone screenshots.
- [ ] Content rating questionnaire.
- [ ] Target API level (Play requires recent — confirm `targetSdkVersion`).
- [ ] Foreground-service (microphone) + Accessibility usage justifications — Play
      asks why the app uses the Accessibility API; answer: "to paste dictated text
      into the focused field for the Flow Bubble feature."

---

## Desktop (Mac / Windows / Linux — all sideloadable)

- **Mac:** currently signed "Apple Development" (your machine only). For others to
  run it: sign with a **Developer ID Application** cert + **notarize** (`xcrun
  notarytool`), then staple, then ship a `.dmg`. Without notarization, Gatekeeper
  blocks it. Add an auto-update path (Sparkle) if you want updates.
- **Windows:** the `.exe` is currently **unsigned** and never run on real Windows.
  Needs: a code-signing cert (else SmartScreen warns), an installer (e.g. Inno
  Setup), and a real-Windows test pass.
- **Linux:** not built yet. Path: package the same sherpa-onnx core as an
  AppImage or `.deb`/Flatpak. New work — scope it after Mac/Windows ship.

---

## Store listing copy (Android, reusable)

- **Title:** Scribe — On-device Voice to Text
- **Short:** Private, offline speech-to-text & translation. No cloud, no account.
- **Full:** Turn speech into text entirely on your device. No sign-up, no
  servers, no tracking — works in airplane mode. Live dictation, downloadable
  models (Whisper, Moonshine, Parakeet, and more), 25+ input languages, on-device
  translation into 59 languages, a dictation keyboard, and a floating Flow Bubble
  that types into any app. Your voice never leaves your phone.

## Open-source / model attribution (ship an "Acknowledgements" screen)
- whisper.cpp / Whisper models — MIT (OpenAI weights, MIT)
- sherpa-onnx — Apache-2.0; Moonshine, NVIDIA Parakeet/Canary, Dolphin per their licenses
- Google ML Kit (translate + language-id) — Google APIs ToS
- React Native, Expo — MIT

---

## Cross-platform hardening checklist (code, no external services)
- [ ] Graceful states: mic/speech denied, no model downloaded, offline during a
      download, low storage, model download failure (retry + clear message).
- [ ] First-run permission priming before the OS prompt.
- [ ] Large-model memory behavior on low-end phones (Whisper small/large).
- [ ] Confirm release JS bundle builds (Metro) — covered by `bundleRelease`.
- [ ] No telemetry / no crash SDK (by design — free, fully local).

## Device-test matrix (the real gate)
- [ ] Android (Pixel): every engine, live + file import, translation (incl. first
      model download), keyboard, Flow Bubble (overlay + accessibility paste),
      Android-14 foreground mic.
- [ ] iOS (iPhone): record/live, translation pods (after `pod install`), keyboard
      clipboard handoff.
- [ ] Windows / Mac: dictation, hotkey, paste, model download.

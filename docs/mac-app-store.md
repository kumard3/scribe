# Bolkit for macOS on the Mac App Store: feasibility

Assessed 2026-09-18 against the code in `mac/` at version 1.3.1 (`ai.scribe.mac`,
Developer ID signed, notarized, Sparkle appcast).

**Verdict: NO-GO as a port of the current app. Conditional GO only for a
separate, reduced product.**

The blocker is not the part everyone expects. System audio capture, Metal
shader compilation and the bundled whisper helper all survive the App Sandbox,
measured directly on this machine. What does not survive is the Accessibility
API layer that the dictation product is built on, plus Sparkle, which
guideline 2.4.5(vii) forbids outright.

---

## How the claims below were established

Two kinds of evidence, kept separate throughout.

**Measured.** A minimal probe app was built, signed twice (once ad-hoc with
only `com.apple.security.device.audio-input`, once ad-hoc with
`com.apple.security.app-sandbox` + `device.audio-input` +
`network.client`) and run. Source in the session scratchpad
(`sbprobe/probe2.swift`, `metalprobe.swift`, `hkprobe.swift`). The sandboxed
build confirmed it was sandboxed by reporting
`NSHomeDirectory() = ~/Library/Containers/ai.scribe.probe.sandboxed/Data`.
Where a first run was confounded by Terminal's own TCC grants, it was re-run
via `open -n` so the app was its own responsible process, and the confounded
numbers were discarded.

**Documented.** Apple pages actually fetched this session, listed at the end.
Nothing here comes from recall.

---

## 1. What the App Sandbox breaks

### 1.1 System audio capture for meeting recording: NOT a blocker (measured)

`mac/Sources/Scribe/MeetingAudio.swift` uses a **Core Audio process tap**, not
ScreenCaptureKit: `CATapDescription(stereoGlobalTapButExcludeProcesses:)` →
`AudioHardwareCreateProcessTap` → `AudioHardwareCreateAggregateDevice` with a
private aggregate device (line 94 onward).

Measured, sandboxed vs not, with `afplay` producing real output during a 6 s
capture window:

| | unsandboxed | sandboxed |
|---|---|---|
| `AudioHardwareCreateProcessTap` | OSStatus 0 | OSStatus 0 |
| `AudioHardwareCreateAggregateDevice` | OSStatus 0 | OSStatus 0 |
| IOProc callbacks in 6 s | 515 | 514 |
| peak sample | 0.185506 | 0.185355 |
| verdict | real audio | real audio |

The tap works identically inside the sandbox and captures genuine system audio.
This is the single most surprising result and it flips the usual assumption.

Caveat, inferred not measured: the probe was ad-hoc signed and no
"System Audio Recording" TCC prompt appeared. A real distribution build will
still be gated by that prompt (`NSAudioCaptureUsageDescription` is already in
`Info.plist`), and Apple provides no API to query it, so a denied grant still
produces a silent track. That is existing behaviour, not a sandbox regression.

No sandbox entitlement specific to process taps was found in Apple's docs, and
none appears to be needed. `com.apple.security.device.audio-input` plus
`com.apple.security.device.microphone` covers it.

### 1.2 Global fn-key push-to-talk and accessibility: THE BLOCKER (documented)

Apple's own page is explicit. From
`developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox`,
section "Review functionality that is incompatible with App Sandbox":

> Certain activities are forbidden by the operating system when an app runs in
> a sandbox. [...] The restricted activities are:
> - Use of Authorization Services API.
> - **Use of accessibility APIs in assistive apps.**
> - Sending Apple Events to arbitrary apps.
> - [...]

That one line takes out four things in this codebase.

**a. `HoldKeyMonitor` (`SystemBridge.swift:57`).** The fn / hold-to-talk key
uses `NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged)`. Apple DTS
(forums thread 820594) states the global-monitor path relies on the
Accessibility privilege and that the sandbox-compatible route is a
`CGEventTap` on the Input Monitoring (ListenEvent) privilege instead.

Measured: `CGEvent.tapCreate(tap: .cghidEventTap, options: .listenOnly, ...)`
returns non-nil inside the sandbox, so the rewrite is viable. (Not fully
isolated: the probe ran under Terminal, which holds Input Monitoring, so tap
creation may have inherited that grant. Treat "the rewrite is viable" as
likely, not proven.)

**b. `Paster.writeDirectly` / `focusedField` / `caret`
(`SystemBridge.swift:131-175`).** The preferred paste path reads
`kAXFocusedUIElementAttribute` from `AXUIElementCreateSystemWide()`, checks
`kAXSelectedTextRangeAttribute`, and writes with
`AXUIElementSetAttributeValue`. This is exactly "use of accessibility APIs in
an assistive app". It has to go.

**c. `CorrectionWatcher` (`CorrectionWatcher.swift`).** Same APIs, same fate.
The learn-from-my-edit feature dies with the AX path.

**d. `Paster.insertLanded` verification.** Without a readable caret there is no
way to tell a successful paste from a silent no-op. The code comment at
`SystemBridge.swift:172` already says why that matters: a wrong guess types the
transcript twice.

**What survives.** Measured under sandbox:
- `RegisterEventHotKey` (Carbon, `HotKeyManager`, `SystemBridge.swift:24`)
  returns OSStatus 0. The user-configurable toggle shortcut is fine.
- `NSPasteboard` read and write are fine.
- `CGEvent(...).post(tap: .cghidEventTap)` (the Cmd-V fallback,
  `SystemBridge.swift:212-218`) is, per Apple DTS in thread 820594, gated by
  the **PostEvent** privilege, which "is compatible with the App Sandbox". The
  confusing part, also from that thread: PostEvent and Accessibility both
  display as "Accessibility" in System Settings, so the user-facing permission
  screen looks unchanged.

So dictation-into-other-apps is not gone, but it degrades from
"write straight into the focused field and verify the caret moved" to
"put it on the clipboard and fire Cmd-V blind".

**Review risk on top of the technical one.** That same Apple forum thread is a
clipboard-manager developer reporting repeated App Review rejections under
guideline 2.4.5 for exactly the `CGEvent.post` pattern. Apple's engineer says
he does not speak for App Review. So the surviving paste path is itself a
documented rejection risk, not a safe harbour.

### 1.3 Sparkle self-update: FATAL, must be removed (documented)

App Store Review Guidelines 2.4.5, fetched verbatim:

> **(vii)** They must use the Mac App Store to distribute updates; other update
> mechanisms are not allowed.

Sparkle is a hard removal: the SPM dependency in `Package.swift`,
`UpdateManager` and the `import Sparkle` in `ScribeApp.swift`, the
"Check for Updates…" menu item in `MenuContent`, the `ditto` of
`Sparkle.framework` in `build.sh`, and the four `SU*` keys in `Info.plist`
(`SUFeedURL`, `SUEnableAutomaticChecks`, `SUAllowsAutomaticUpdates`,
`SUPublicEDKey`).

### 1.4 Model downloads to Application Support: works, but the sharper risk is 2.4.5(iv)

Measured under sandbox: HTTPS GET returns 200; `FileManager` writes succeed;
`Process` exec of `/usr/bin/tar` (used by `ModelStore.swift:274` and
`SupportModelStore.swift:151`) exits 0. Nothing here is blocked.

What changes is the path. `ModelStore.root` and `MeetingRecorder.root` resolve
via `.applicationSupportDirectory`, which the sandbox redirects:

```
unsandboxed: /Users/kumardeepanshu/Library/Application Support
sandboxed:   ~/Library/Containers/ai.scribe.probe.sandboxed/Data/Library/Application Support
```

Measured on this machine, `~/Library/Application Support/Scribe` currently holds
**4.2 GB** of models, meetings and diagnostics. A sandboxed build cannot see any
of it.

The guideline exposure is two-sided:

- **2.5.2** ("may not download, install, or execute code which introduces or
  changes features or functionality of the app") is the one people worry about.
  Model weights are data, and Apple documents downloading and compiling Core ML
  models at runtime as a supported pattern, so GGUF/ONNX weights are defensible.
- **2.4.5(iv)** is the sharper one: "They may not download or install
  standalone apps, kexts, additional code, **or resources to add functionality
  or significantly change the app from what we see during the review process**."
  Bolkit ships with essentially no ASR capability until a model is downloaded
  from `ModelCatalog` (huggingface.co and github.com release URLs). A reviewer
  who installs the app sees a dictation app that cannot dictate until it
  fetches a 600 MB to 4 GB resource. That is a plausible 2.4.5(iv) rejection and
  it is not a technical problem you can engineer around: the fix is bundling a
  default model in the app, which means a multi-GB App Store binary.

### 1.5 MLX / llama.cpp with JIT-compiled Metal shaders: NOT a blocker (measured)

`build.sh` builds llama.cpp with `-DGGML_METAL_EMBED_LIBRARY=ON`. Measured:
`libggml-metal.dylib` contains 60 occurrences of `metal_stdlib` and 2
references to `newLibraryWithSource:options:error:`, and zero references to
`newLibraryWithData`. So the embedded artefact is Metal **source**, compiled at
runtime. That is genuine runtime shader compilation.

MLX is different: `Bolkit.app/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib`
is a precompiled library, so MLX does not compile from source in this
configuration.

Measured, sandboxed vs not, with no JIT entitlement of any kind:

| | unsandboxed | sandboxed |
|---|---|---|
| `MTLCreateSystemDefaultDevice` | Apple M3 Pro | Apple M3 Pro |
| `makeLibrary(source:)` | OK | OK |
| `makeComputePipelineState` | OK (1024 threads/group) | OK (1024 threads/group) |

Metal's runtime compiler runs out of process, so no `allow-jit` and no
`allow-unsigned-executable-memory` is needed. `disable-library-validation` is
also unnecessary: every bundled dylib (`libllama`, `libggml*`,
`libsherpa-onnx-c-api`, `libonnxruntime`) is signed by the same team, so
library validation is satisfied by signing them with the distribution identity.

### 1.6 Bundled whisper-cli helper: works, but must be relocated (measured + documented)

`NativeTranscriptionWorker.swift:246` runs
`Contents/Helpers/Whisper/whisper-cli`, and lines 149/258/276/423 re-exec the
app's own main binary with `--transcribe` / `--asr` / `--transcribe-batch`.

Measured under sandbox: spawning `/usr/bin/tar` exits 0, and spawning the app's
own executable as a child exits with the child's own status (42, as the probe
was written to do). Child processes run fine.

Apple's "Embedding a command-line tool in a sandboxed app" doc requires the
helper be signed with `com.apple.security.app-sandbox` **and**
`com.apple.security.inherit`, must **not** carry
`com.apple.security.get-task-allow` (incompatible with `inherit`), and should
be placed in `Contents/MacOS` via the Executables copy destination. So
`Contents/Helpers/Whisper/` needs to move and its two dylibs need to live in
`Contents/Frameworks` under the normal nested-code rules.

### 1.7 Smaller items

| Thing | Where | Under sandbox |
|---|---|---|
| Audio file import | `AudioImport.swift:13` `NSOpenPanel` | Needs `com.apple.security.files.user-selected.read-only`. Fine. |
| Login item | `SystemBridge.swift` `SMAppService.mainApp` | Allowed. 2.4.5(iii) requires consent; the dashboard toggle satisfies that. |
| `NSWorkspace.shared.open("x-apple.systempreferences:...")` | `ScribeApp.swift:167`, `Onboarding.swift:126/146`, `Dashboard.swift:443/873` | Opening System Settings still works, but most of these prompts point at Accessibility, which no longer applies. Onboarding needs rewriting anyway. |
| Reveal in Finder | `MeetingRecorder.swift:88/191` | Works, but reveals a path inside the container. |
| Ollama at `127.0.0.1:11434` | `OllamaRuntime.swift:12` | Needs `network.client`. Technically fine; it is a dependency on user-installed non-App-Store software, so hide it in the MAS build. |
| Diagnostics path | `NativeTranscriptionWorker.swift:577` hardcodes `Library/Application Support/Scribe/Diagnostics` relative to home | Resolves inside the container. Works, but is a hand-built path rather than `FileManager.url(for:)`, which Apple's doc explicitly tells you to use. |

---

## 2. Entitlements required

For the app bundle:

```
com.apple.security.app-sandbox              true   required for MAS, Apple doc is explicit
com.apple.security.device.audio-input       true   already present
com.apple.security.device.microphone        true   MISSING today, sandbox needs it
com.apple.security.network.client           true   model downloads, Ollama
com.apple.security.files.user-selected.read-only  true   NSOpenPanel import
com.apple.application-identifier            Q84L632A4A.<bundle id>   from the profile
com.apple.developer.team-identifier         Q84L632A4A               from the profile
```

For the embedded whisper helper:

```
com.apple.security.app-sandbox   true
com.apple.security.inherit       true
```

Apple's `com.apple.security.device.audio-input` page describes it as the
**Hardened Runtime** Resource Access entitlement. The App Sandbox counterpart
listed on Apple's App Sandbox page is `com.apple.security.device.microphone`.
Ship both.

**Not needed** (measured in 1.5): `com.apple.security.cs.allow-jit`,
`com.apple.security.cs.allow-unsigned-executable-memory`,
`com.apple.security.cs.disable-library-validation`.

**Requiring a special request from Apple: none.** The entitlements that go
through Apple's request form are things like
`com.apple.developer.endpoint-security.client` and
`com.apple.developer.persistent-content-capture`, neither of which this app
uses. System audio recording is a user TCC prompt, not an Apple-granted
entitlement, and no process-tap entitlement exists to request.

Temporary-exception entitlements
(`com.apple.security.temporary-exception.apple-events` and friends) should not
be considered a workaround for the Accessibility problem. They are not a route
Apple grants for Mac App Store submissions.

---

## 3. Bundle identifier and App Store Connect record

Queried read-only through `scripts/asc.py` on 2026-09-18.

**Registered App IDs for team Q84L632A4A** (`GET /v1/bundleIds`), 7 total:

```
UNIVERSAL  com.kumard3.health.watchbridge
UNIVERSAL  ai.localvoice.app
UNIVERSAL  ai.localvoice.app.ScribeKeyboard
UNIVERSAL  ai.localvoice.app.ScribeWidget
UNIVERSAL  ai.localvoice.app.VoxKeyboard
UNIVERSAL  ai.localvoice.app.VoxWidget
UNIVERSAL  *                                  (XC Wildcard)
```

`ai.scribe.mac` is **not registered**. It exists only as a code-signing
identifier on the Developer ID build, which does not require an App ID. It
cannot be used for a Mac App Store upload until it is registered, and a MAS
build must carry `com.apple.application-identifier = Q84L632A4A.<id>`, which
Developer ID builds do not have.

**App records** (`GET /v1/apps`), exactly one:

```
6795213062  Bolkit: Voice to Text  ai.localvoice.app  sku ai.localvoice.app
```

**Versions on that record** (`GET /v1/apps/6795213062/appStoreVersions`):

```
ef6d448b-7bf9-4910-aa85-b7ac974e218f  MAC_OS  1.0  PREPARE_FOR_SUBMISSION
                                      created 2026-08-11, releaseType AFTER_APPROVAL,
                                      copyright "2026 Kumar Deepanshu", build: null
1c01e7db-8d2d-4abc-9b05-338a5b092909  IOS     1.0  REJECTED
```

`GET /v1/apps/6795213062/preReleaseVersions` returns one entry, platform
**IOS** only. No macOS build has ever been uploaded.

### What that means

**A Mac App Store slot already exists.** It was created 2026-08-11 by adding
the macOS platform to the existing app record, which is why it shares the
record, the SKU and the app-level metadata (`appInfos` is one shared record
across platforms) with the iOS app.

**It is a genuine native macOS slot, not "Designed for iPad".** Making an iOS
app available on Apple Silicon Macs is an availability flag and does not create
a `MAC_OS` `appStoreVersion`. A distinct `MAC_OS` version record means the
macOS platform is enabled on the record.

**It does not lock you into Mac Catalyst.** App Store Connect has no field
distinguishing Catalyst from native AppKit/SwiftUI; both upload under platform
`MACOS`. What decides it is the `LC_BUILD_VERSION` platform in the uploaded
binary. A native SwiftUI Mac app built by SwiftPM uploads against this slot
fine.

**The bundle id it expects is `ai.localvoice.app`, not `ai.scribe.mac`.** One
app record means one bundle identifier across all its platforms. So:

- To use the existing slot: the MAS build must ship
  `CFBundleIdentifier = ai.localvoice.app`. That gives Universal Purchase with
  the iOS app for free, and no new App ID is needed. The cost is entanglement:
  shared name, subtitle, privacy declarations and pricing with an iOS record
  that is currently REJECTED.
- To keep them separate: register a new App ID (for example
  `ai.localvoice.mac`), create a second app record, lose Universal Purchase,
  and get an independent listing.

**Either way, a separate bundle id from the direct-download build is
mandatory.** `ai.scribe.mac` stays on the Developer ID product. A single
bundle id cannot be both a sandboxed MAS build and an unsandboxed Sparkle
build, and shipping the same id twice would have macOS treat the two installs
as the same app.

---

## 4. Changes to `mac/build.sh`, and what they cost existing users

Current state, verified with `codesign -dvvv --entitlements -` on the built
`Bolkit.app`:

```
Identifier=ai.scribe.mac
Authority=Developer ID Application: kumar deepanshu (Q84L632A4A)
flags=0x10000(runtime)          hardened runtime
Notarization Ticket=stapled
entitlements: com.apple.security.device.audio-input only
```

A MAS build needs, in `build.sh`:

1. **Signing identity.** `Developer ID Application` becomes `Apple Distribution`
   (Apple's current name; the Mac App Distribution certificate type). The
   existing `security find-identity` block that prefers Developer ID has to be
   inverted or parameterised.
2. **Provisioning profile.** A Mac App Store profile for the chosen App ID,
   copied to `Bolkit.app/Contents/embedded.provisionprofile`. The Developer ID
   build has none, so this is a new step.
3. **Entitlements.** Replace `Scribe.entitlements` (one key) with the sandbox
   set from section 2, plus a second `helper.entitlements` with
   `app-sandbox` + `inherit` for `whisper-cli`.
4. **Signing order.** Nested code must be signed inside out: dylibs in
   `Contents/Frameworks`, then the helper with its own entitlements, then the
   app. The current script already does dylibs first, but it uses
   `codesign --deep` on the app, which cannot apply per-helper entitlements.
   Drop `--deep`.
5. **Strip Sparkle.** Remove the `ditto` of `Sparkle.framework`, the SPM
   dependency, `UpdateManager`, the menu item and the four `SU*` Info.plist
   keys.
6. **Relocate the helper.** `Contents/Helpers/Whisper/whisper-cli` to
   `Contents/MacOS/whisper-cli`, its dylibs to `Contents/Frameworks`. Note the
   existing comment in `build.sh` about whisper.cpp's ggml ABI colliding with
   llama.cpp's; merging both into `Contents/Frameworks` may resurrect that
   collision, so the two ggml sets need distinct install names or the helper
   needs an `@loader_path` layout that keeps them apart. This is the one change
   with real unknown risk.
7. **Bundle id and Info.plist.** `CFBundleIdentifier` to the registered App ID.
   `LSMinimumSystemVersion` 14.0 is fine.
8. **Packaging.** MAS submission is a signed installer package, not a zip:
   `productbuild --component Bolkit.app /Applications --sign "3rd Party Mac
   Developer Installer: ..."`, then upload. Guideline 2.4.5(ii) requires
   packaging with Xcode-provided technologies, which `productbuild` is.
   Notarization is not part of this path (App Store review replaces it).
9. **Keep both.** Gate all of the above behind something like
   `SCRIBE_MAS=1` rather than replacing the Developer ID path.

### What breaks if you convert `build.sh` in place instead of forking it

- **Sparkle updates stop for every 1.3.1 user.** They have no in-app path to a
  newer version and the appcast would go stale. `RELEASING.md` already records
  that pre-1.3.0 users needed a manual reinstall once; this would repeat that,
  permanently.
- **The bundle id change revokes TCC grants.** `RELEASING.md` already documents
  that replacing the bundle the wrong way makes macOS "treat the next copy as a
  different app and revoke its Microphone and Accessibility grants, which looks
  exactly like the app silently breaking". A bundle id change guarantees that.
- **4.2 GB of downloaded models are orphaned.** Measured on this machine.
  Everything under `~/Library/Application Support/Scribe` becomes invisible to
  a sandboxed build and has to be re-downloaded into the container.
- **Direct-download users lose the AX direct-insert path** for no reason, since
  they were never subject to the sandbox.

Fork it. Do not convert it.

---

## 5. Honest verdict

**This is a big job, and the most likely outcome is a rejection or a
materially worse product. NO-GO.**

Ranked by what actually decides it:

1. **Guideline 2.4.5(vii) removes Sparkle.** Certain, mechanical, and by itself
   not a reason to stop. It only means the MAS build is a second product.
2. **"Use of accessibility APIs in assistive apps" is listed by Apple as
   forbidden under the App Sandbox.** This is the real one. It deletes the
   direct-caret insert, the paste verification, and `CorrectionWatcher`
   outright, and forces the fn-key hold monitor to be rewritten on a
   `CGEventTap`. What remains is clipboard plus a blind synthetic Cmd-V.
3. **That surviving Cmd-V path is itself a documented 2.4.5 rejection
   pattern.** Apple's own forums carry a clipboard-manager developer reporting
   repeated 2.4.5 rejections for `CGEvent.post`, with Apple's engineer
   confirming the API is sandbox-legal but declining to speak for App Review.
   So the degraded feature is not even safely shippable.
4. **Guideline 2.4.5(iv) versus the model catalog.** A dictation app that
   downloads its ASR model after install is downloading "resources to add
   functionality" relative to what the reviewer sees. Avoiding it means
   bundling a model and shipping a multi-gigabyte binary.
5. Everything else is work, not risk. The tap, Metal, subprocesses and
   downloads all measured clean.

### Features that must be removed or degraded, with the guideline

| Feature | Fate | Cause |
|---|---|---|
| Sparkle auto-update | removed | Review Guideline 2.4.5(vii) |
| Direct caret insert (`Paster.writeDirectly`) | removed | App Sandbox: "Use of accessibility APIs in assistive apps" |
| Paste-landed verification (`insertLanded`, caret read) | removed | same |
| `CorrectionWatcher` learn-from-edits | removed | same |
| fn / hold-to-talk via `NSEvent` global monitor | rewritten on `CGEventTap` + Input Monitoring | same |
| Auto-paste via Cmd-V | kept but at review risk | Guideline 2.4.5, documented rejections |
| Downloadable model catalog | at risk, may need a bundled default | Guideline 2.4.5(iv) |
| Ollama backend | hide in the MAS build | dependency on non-App-Store software |
| Existing users' 4.2 GB of models | re-download | sandbox container redirect |

### If you want a store presence anyway

Ship a deliberately smaller product, not a port. "Bolkit Recorder": meeting
recording plus file import plus on-device transcription, with the system
audio tap (which measured clean) as the headline, one bundled small model, and
no system-wide dictation at all. That app is sandbox-clean, has no
Accessibility surface, no Sparkle, and no 2.4.5(iv) exposure. Keep system-wide
dictation exclusively on the Developer ID build, where it works properly, and
use the App Store listing to point at it.

### Ordered task list, only if GO

Do steps 1 to 3 before writing any code. If step 3 comes back negative, stop.

1. Decide the record. Either ship as `ai.localvoice.app` into the existing
   `MAC_OS` slot (`ef6d448b-...`, Universal Purchase, shared listing with a
   REJECTED iOS sibling) or register a new App ID and create a second record.
2. Decide the product. Full port, or the reduced recorder above. The rest of
   this list assumes the reduced product; a full port adds steps 8 and 9 and a
   rejection risk that is not worth paying down.
3. Ask App Review directly, before building, whether a downloaded ASR model
   falls under 2.4.5(iv), and whether the Cmd-V insertion pattern is
   acceptable for a dictation app. Both answers are cheap to get and both can
   end the project.
4. Fork the build: `SCRIBE_MAS=1` branch in `build.sh` covering identity,
   embedded profile, sandbox entitlements, no `--deep`, no Sparkle,
   `productbuild` packaging. Leave the Developer ID path untouched.
5. Add `com.apple.security.device.microphone`, `network.client` and
   `files.user-selected.read-only`; keep `device.audio-input`.
6. Move `whisper-cli` to `Contents/MacOS`, sign it with `app-sandbox` +
   `inherit` and no `get-task-allow`, move its dylibs to
   `Contents/Frameworks`, and re-verify the ggml ABI separation that the
   current `Contents/Helpers/Whisper` layout exists to protect.
7. Replace hardcoded `Library/Application Support/Scribe` paths
   (`NativeTranscriptionWorker.swift:577`) with `FileManager.url(for:)` so the
   container redirect is consistent everywhere.
8. Compile out Sparkle, `UpdateManager`, the update menu item and the `SU*`
   Info.plist keys.
9. Full port only: delete `CorrectionWatcher` and the AX branch of `Paster`,
   rewrite `HoldKeyMonitor` on a listen-only `CGEventTap`, and rewrite
   `Onboarding` and the Dashboard permission rows to request Input Monitoring
   rather than Accessibility.
10. Bundle a default model so the app is functional at first launch with no
    download.
11. Verify locally with
    `codesign -dvvv --entitlements - Bolkit.app` (expect
    `com.apple.security.app-sandbox true`) and Activity Monitor's Sandbox
    column, per Apple's own verification steps.
12. Upload one build to the existing macOS slot and let review answer the
    remaining questions before investing in metadata and screenshots.

---

## Apple documentation actually fetched for this assessment

- App Store Review Guidelines, 2.4.5 (i) to (ix), 2.5.1, 2.5.2, 2.5.4:
  https://developer.apple.com/app-store/review/guidelines/
- App Sandbox ("To distribute a macOS app through the Mac App Store, you must
  enable the App Sandbox capability"), plus the entitlement topic list
  including `com.apple.security.device.microphone`:
  https://developer.apple.com/documentation/security/app-sandbox
- Protecting user data with App Sandbox, section "Review functionality that is
  incompatible with App Sandbox" (the accessibility-APIs prohibition), and the
  container/`FileManager.url(for:)` guidance:
  https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox
- Embedding a command-line tool in a sandboxed app (`com.apple.security.inherit`,
  no `get-task-allow`, Executables destination):
  https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app
- Audio Input Entitlement (`com.apple.security.device.audio-input`, described as
  a Hardened Runtime Resource Access entitlement):
  https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.audio-input
- Apple DTS on which TCC privileges are App Sandbox compatible (Accessibility
  no, PostEvent and ListenEvent yes) and on 2.4.5 rejections for `CGEvent.post`:
  https://developer.apple.com/forums/thread/820594
- Apple DTS on the sandbox-compatible replacement for a global event monitor:
  https://developer.apple.com/forums/thread/811443
- Apple Developer certificate types for Mac App Store versus Developer ID:
  https://developer.apple.com/support/certificates/

### Claims that are documented but not measured

- That a sandboxed app cannot obtain or use the Accessibility TCC grant.
  Verifying this requires a human granting Accessibility to a sandboxed test
  app in System Settings, which was not done. The prohibition is taken from
  Apple's own page, quoted above.
- That App Review will or will not accept the `CGEvent.post` insertion pattern
  or the downloadable model catalog. Both are inferences from published
  guideline text and third-party rejection reports, not from a submission.
- That the real distribution build will still see the System Audio Recording
  TCC prompt. The ad-hoc probe did not surface one.

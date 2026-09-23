# Pre-submission questions for App Review (macOS)

Channel: App Store Connect → Contact Us → App Review → Pre-submission questions.
App record: 6795213062 (Bolkit). A macOS version slot already exists (1.0, Prepare for
Submission, created 2026-08-11, no build attached) expecting bundle id `ai.localvoice.app`.

Status: SENT 2026-09-18 via Contact Us > App Review > Other App Review questions > Email.
Apple case ID 102967562643. Filed as app name Bolkit, Apple ID 6795213062, platform macOS.
Reply goes to kumardeepanshu157200@gmail.com. Question 1 decides go/no-go; see docs/mac-app-store.md.

---

Subject: Pre-submission guidance for a sandboxed on-device dictation utility (Bolkit)

Hello,

We ship Bolkit, an on-device dictation and meeting transcription app for macOS, currently
distributed outside the Mac App Store with Developer ID. All speech recognition runs locally;
we operate no server and the app has no accounts or purchases. Before we invest in a Mac App
Store build we would like guidance on three points, so we do not submit something that cannot
be approved.

1. Accessibility API use in a dictation utility, inside the App Sandbox

The app's main function is push to talk dictation: the user holds a key, speaks, and the
transcribed text is inserted into the text field of whatever app they are using. We do this
with the Accessibility API (AXUIElement) after the user grants Accessibility permission in
System Settings, which is the same mechanism assistive and dictation tools have used for years.

The App Sandbox documentation lists "use of accessibility APIs in assistive apps" as
unsupported under the sandbox. Our questions:

  a. Can a sandboxed Mac App Store app use the Accessibility API to insert text into another
     app's focused field, when the user has explicitly granted Accessibility permission?
  b. If not, is synthesising a paste (writing to the pasteboard and sending Command V) an
     acceptable alternative for this purpose, or would that be considered a workaround that
     falls foul of the guidelines?
  c. If neither is acceptable, is there a supported route for a dictation app on the Mac App
     Store to deliver text into other applications?

2. Downloading open-weight speech models at the user's request

The app ships with a small default engine and offers optional, one-time downloads of
open-weight speech and language models (Whisper under MIT, NVIDIA NeMo via k2-fsa under
Apache 2.0 and CC-BY, Google Gemma under the Gemma Terms of Use). These are model weight data
files, not executables and not code. They are downloaded only when the user chooses a model,
and stored in the app container.

  a. Does this comply with guideline 2.4.5(iv), given the downloaded files are data rather
     than executable code?
  b. For completeness: the local inference library compiles Metal compute shaders at runtime
     from shader source that is compiled into our own binary. Nothing is downloaded for this.
     Does that require any particular entitlement on the Mac App Store?

3. System audio capture for meeting recording

The meeting recorder captures system audio using a Core Audio process tap
(AudioHardwareCreateProcessTap), with the user granting the system's audio capture permission.
We have verified this works inside the App Sandbox with the audio-input entitlement. Is any
additional entitlement or review information expected for this on the Mac App Store?

We would rather ask now than submit a build that has to be rejected. Thank you for your time.

Kumar

# Vox Voice — iOS keyboard extension

iOS forbids keyboard extensions from using the microphone (even with Full Access),
so this keyboard hands off to the main Vox app to record **on-device**, then inserts
the result. Same pattern Wispr Flow uses, minus the cloud.

**This target is wired into the Xcode project and builds + embeds** (added via
`scripts/add-ios-keyboard.rb`). Files: `KeyboardViewController.swift`, `Info.plist`,
`VoxKeyboard.entitlements`. Bundle id `ai.localvoice.app.VoxKeyboard`.

## How the handoff works (clipboard-based — no App Group)

1. In any app, switch to **Vox Voice** and tap **🎤 Dictate**.
2. The keyboard opens the Vox app via `vox://dictate-session`.
3. Vox auto-starts **Live** on-device dictation; when you stop, it copies the
   transcript to the clipboard (`Clipboard.setStringAsync`, wired in `App.tsx`).
4. Swipe back to your app and tap **📋 Paste** on the keyboard to insert it.

We use the clipboard instead of an **App Group** on purpose: App Groups require the
App ID to have that capability registered in the Apple Developer portal, which
headless automatic signing can't do. The clipboard needs only Full Access (already
set via `RequestsOpenAccess`). If you later enable an App Group in the portal, you
can switch to a silent auto-insert (write to `UserDefaults(suiteName:)` + read on
`viewWillAppear`) for a more seamless paste.

## To test on device
1. Build/install Vox, open it once, grant the microphone.
2. Settings → General → Keyboard → Keyboards → Add New Keyboard → **Vox Voice**;
   tap it → enable **Allow Full Access**.
3. In any app, 🌐 → Vox Voice → Dictate → speak → swipe back → 📋 Paste.

## Optional polish later
- Auto-insert via App Group (portal capability) instead of manual Paste.
- Run the transcript through `polish()` before copying (filler/cleanup).

# Releasing Bolkit for macOS

Bolkit (named Scribe up to 1.3.0) uses Sparkle 2, since 1.3.0, for automatic updates. The app checks this
feed on launch and users can also choose **Check for Updates…**:

`https://github.com/kumard3/scribe/releases/download/scribe-macos-updates/appcast.xml`

Updates are rolled out in daily Sparkle cohorts. The archive, appcast, and
release notes are signed with the app's Ed25519 key. The private key is stored in
the local login Keychain under `ai.scribe.mac.updates`; the app contains only
the public key.

## One-time GitHub setup

Add these repository Actions secrets:

- `APPLE_DEVELOPER_ID_CERTIFICATE_P12_BASE64`
- `APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD`
- `APPLE_ID`
- `APPLE_APP_SPECIFIC_PASSWORD`
- `APPLE_TEAM_ID` (`Q84L632A4A`)
- `BUILD_KEYCHAIN_PASSWORD` (a random CI-only password)
- `SPARKLE_PRIVATE_KEY`

Export the Sparkle secret without committing it:

```bash
cd mac
.build/artifacts/sparkle/Sparkle/bin/generate_keys \
  --account ai.scribe.mac.updates -x /tmp/scribe-sparkle-private-key
gh secret set SPARKLE_PRIVATE_KEY < /tmp/scribe-sparkle-private-key
```

Export the **Developer ID Application** certificate and private key from
Keychain Access as a password-protected `.p12`, then base64-encode that file for
`APPLE_DEVELOPER_ID_CERTIFICATE_P12_BASE64`. Never commit either private key.

## Publish

Update both versions in `Info.plist`, commit the release, then push the matching
tag:

```bash
git tag v1.3.0
git push origin v1.3.0
```

The workflow builds arm64+x86_64, requires Developer ID signing and hardened
runtime, submits to Apple's notary service, staples the ticket, creates the
Sparkle appcast, publishes the versioned release, and updates the stable
`scribe-macos-updates` feed release. It refuses to upload if any signing or
notarization step fails. The fixed feed URL is intentionally independent of
GitHub's “latest release,” so model-only releases cannot break app updates.

Versions earlier than 1.3.0 did not contain Sparkle, so those users need to
install 1.3.0 once manually. Every later version can update in place.

## Installing a local build over /Applications

Replace the bundle in place. `rm -rf` on the installed app makes macOS treat
the next copy as a different app and revoke its Microphone and Accessibility
grants, which looks exactly like the app silently breaking. A plain `ditto`
over it leaves files the new build dropped (old versioned dylibs), which breaks
the code-signature seal, so sync with `--delete`:

```bash
osascript -e 'quit app "Bolkit"'
rsync -a --delete Bolkit.app/ /Applications/Bolkit.app/   # no rm -rf first
codesign --verify --deep --strict /Applications/Bolkit.app
open /Applications/Bolkit.app
```

If permissions were already lost, reset and re-grant them:

```bash
tccutil reset Microphone ai.scribe.mac
tccutil reset Accessibility ai.scribe.mac
```

## Mac App Store build

`SCRIBE_MAS=1 ./build.sh release` builds a separate, sandboxed product as
`mas/Bolkit.pkg`: bundle id `ai.localvoice.app` (the same App Store record as iOS),
no Sparkle, and no Accessibility API. Holding the dictation key uses a listen-only
event tap (Input Monitoring) and inserting text is a synthetic Cmd-V (Accessibility
pane, PostEvent). Direct field writes and correction learning exist only in the
Developer ID build.

It needs the Apple Distribution and Mac Installer Distribution certificates in the
login keychain and the Mac App Store profile at
`~/.appstoreconnect/Bolkit_MAS.provisionprofile` (or `SCRIBE_MAS_PROFILE`).
Upload with `xcrun altool --upload-package mas/Bolkit.pkg --api-key <id> --api-issuer <issuer>`
(validate first with `--validate-app mas/Bolkit.pkg -t macos` and the same key flags).

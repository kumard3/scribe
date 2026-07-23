# Releasing Scribe for macOS

Scribe 1.3.0 and later use Sparkle 2 for automatic updates. The app checks this
feed on launch and users can also choose **Check for Updates…**:

`https://github.com/kumard3/scribe/releases/download/scribe-macos-updates/appcast.xml`

Updates are rolled out in daily Sparkle cohorts. The archive, appcast, and
release notes are signed with Scribe's Ed25519 key. The private key is stored in
the local login Keychain under `ai.scribe.mac.updates`; the app contains only
the public key.

## One-time GitHub setup

Add these repository Actions secrets:

- `APPLE_DEVELOPER_ID_CERTIFICATE_P12_BASE64`
- `APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD`
- `APPLE_ID`
- `APPLE_APP_SPECIFIC_PASSWORD`
- `APPLE_TEAM_ID` (`DBJ6KVSZ88`)
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

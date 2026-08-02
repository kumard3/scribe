#!/bin/bash
# Archive, export, validate and upload Scribe to App Store Connect.
#
# Prerequisites, both one-time:
#   1. Xcode > Settings > Accounts: sign in (needs 2FA). Without this,
#      exportArchive fails with "No signing certificate iOS Distribution found".
#   2. App Store Connect API key (role App Manager) saved to
#      ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8
#
# Usage: ASC_KEY_ID=XXX ASC_ISSUER_ID=YYY ./scripts/ios-release.sh [--upload]

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-/tmp/scribe-release}"
TEAM=Q84L632A4A

mkdir -p "$OUT"
cat > "$OUT/ExportOptions.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>app-store-connect</string>
	<key>teamID</key><string>Q84L632A4A</string>
	<key>signingStyle</key><string>automatic</string>
	<key>uploadSymbols</key><true/>
	<key>destination</key><string>export</string>
</dict>
</plist>
PLIST

rm -rf "$OUT/Scribe.xcarchive" "$OUT/export"

echo "==> Archiving"
xcodebuild -workspace "$ROOT/ios/Scribe.xcworkspace" -scheme Scribe -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$OUT/Scribe.xcarchive" \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=$TEAM CODE_SIGN_STYLE=Automatic archive

echo "==> Exporting App Store IPA"
xcodebuild -exportArchive -archivePath "$OUT/Scribe.xcarchive" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -exportPath "$OUT/export" \
  -allowProvisioningUpdates

IPA="$OUT/export/Scribe.ipa"
echo "==> Built $IPA ($(du -h "$IPA" | cut -f1))"

if [ -z "${ASC_KEY_ID:-}" ] || [ -z "${ASC_ISSUER_ID:-}" ]; then
  echo "ASC_KEY_ID / ASC_ISSUER_ID unset, stopping before upload."
  exit 0
fi

echo "==> Validating"
xcrun altool --validate-app -f "$IPA" -t ios \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"

if [ "${1:-}" = "--upload" ]; then
  echo "==> Uploading"
  xcrun altool --upload-app -f "$IPA" -t ios \
    --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
else
  echo "Validation passed. Re-run with --upload to submit the build."
fi

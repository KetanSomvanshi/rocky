#!/usr/bin/env bash
# Build, code-sign, notarize, and staple a distributable Rocky.app, then zip it
# for a GitHub release. Produces a binary that runs with NO Gatekeeper
# "unidentified developer" prompt.
#
# Prerequisites (one-time):
#   - Apple Developer Program membership (https://developer.apple.com/programs/).
#   - A "Developer ID Application" certificate in your login keychain
#     (Xcode → Settings → Accounts → Manage Certificates → +).
#   - Notarization credentials — either a stored notarytool profile, or the
#     APPLE_ID / APPLE_TEAM_ID / APPLE_APP_PASSWORD env vars below. Create an
#     app-specific password at https://appleid.apple.com → Sign-In & Security.
#
# Usage:
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE="rocky-notary"  scripts/release.sh 1.0.0
#   # …or instead of NOTARY_PROFILE:
#   APPLE_ID=you@example.com APPLE_TEAM_ID=TEAMID APPLE_APP_PASSWORD=xxxx-xxxx-xxxx-xxxx \
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"  scripts/release.sh 1.0.0
set -euo pipefail

VERSION="${1:-1.0.0}"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$SRC/build"
APP="$BUILD/Rocky.app"
ZIP="$BUILD/Rocky-$VERSION.zip"

: "${DEVELOPER_ID:?set DEVELOPER_ID to your 'Developer ID Application: …' identity}"

rm -rf "$BUILD"; mkdir -p "$APP/Contents/MacOS"

echo "▸ Compiling Rocky $VERSION…"
xcrun swiftc -O "$SRC/main.swift" -o "$APP/Contents/MacOS/Rocky"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Rocky</string>
  <key>CFBundleIdentifier</key><string>com.ketan.rocky</string>
  <key>CFBundleName</key><string>Rocky</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
</dict></plist>
PLIST

echo "▸ Signing with hardened runtime…"
codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "▸ Zipping for notarization…"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

echo "▸ Submitting to Apple notary service (this can take a few minutes)…"
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
else
  : "${APPLE_ID:?set APPLE_ID or NOTARY_PROFILE}"
  : "${APPLE_TEAM_ID:?set APPLE_TEAM_ID or NOTARY_PROFILE}"
  : "${APPLE_APP_PASSWORD:?set APPLE_APP_PASSWORD or NOTARY_PROFILE}"
  xcrun notarytool submit "$ZIP" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" --wait
fi

echo "▸ Stapling the notarization ticket…"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "▸ Re-zipping the stapled app for distribution…"
rm -f "$ZIP"; /usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

echo "✅ Notarized build ready: $ZIP"
echo "   sha256: $(shasum -a 256 "$ZIP" | awk '{print $1}')"
echo "   Attach it to the GitHub release, e.g.:"
echo "     gh release create v$VERSION '$ZIP' --generate-notes"

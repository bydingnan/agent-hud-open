#!/usr/bin/env bash
# Build a signed DMG for distribution (optional notarization).
# Requires a local codesign identity; never commits team IDs or keychain profiles.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Agent HUD Open"
APP_DIR="$ROOT/build/$APP_NAME.app"
STAGE="$ROOT/build/dmg-stage"
OUTPUT_DIR="${OUTPUT_DIR:-$HOME/Downloads}"
IDENTITY="${CODESIGN_IDENTITY:-}"
KEYCHAIN_PROFILE="${KEYCHAIN_PROFILE:-}"
SKIP_NOTARY="${SKIP_NOTARY:-0}"

if [[ -z "$IDENTITY" ]]; then
  cat >&2 <<EOF
CODESIGN_IDENTITY is required.
Example:
  CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" $0
EOF
  exit 2
fi

"$ROOT/scripts/build-app.sh" release

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")"
if [[ -z "$VERSION" ]]; then
  echo "CFBundleShortVersionString missing from $APP_DIR" >&2
  exit 1
fi
mkdir -p "$OUTPUT_DIR"
DMG="$OUTPUT_DIR/Agent-HUD-Open-${VERSION}.dmg"

# Re-sign with Hardened Runtime + timestamp when notarizing.
codesign --force --deep --options runtime --timestamp \
  --sign "$IDENTITY" \
  --identifier app.agenthud.open \
  "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
echo "Signed: $APP_DIR ($VERSION)" >&2

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP_DIR" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
codesign --verify --strict "$DMG"
echo "DMG: $DMG" >&2

if [[ "$SKIP_NOTARY" == "1" ]]; then
  echo "Skipped notarization (SKIP_NOTARY=1)." >&2
  exit 0
fi

if [[ -z "$KEYCHAIN_PROFILE" ]]; then
  cat >&2 <<EOF
KEYCHAIN_PROFILE is required for notarization (or set SKIP_NOTARY=1).
Store credentials once:
  xcrun notarytool store-credentials "your-profile" \
    --apple-id "YOUR_APPLE_ID" --team-id "YOUR_TEAM_ID" --password "app-specific-password"
Then:
  KEYCHAIN_PROFILE=your-profile CODESIGN_IDENTITY="..." $0
EOF
  exit 2
fi

if ! xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" >/dev/null 2>&1; then
  cat >&2 <<EOF
No notary credentials for keychain profile "$KEYCHAIN_PROFILE".
Create an app-specific password at https://appleid.apple.com then run:

  xcrun notarytool store-credentials "$KEYCHAIN_PROFILE" \
    --apple-id "YOUR_APPLE_ID" --team-id "YOUR_TEAM_ID" --password "app-specific-password"

Then re-run: $0
EOF
  exit 2
fi

xcrun notarytool submit "$DMG" --keychain-profile "$KEYCHAIN_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl -a -t open --context context:primary-signature -v "$DMG" || true
echo "Notarized: $DMG" >&2

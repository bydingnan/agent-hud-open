#!/usr/bin/env bash
# Build a Developer ID–signed DMG for distribution (optional notarization).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Agent HUD Open"
APP_DIR="$ROOT/build/$APP_NAME.app"
DMG="$ROOT/build/Agent-HUD-Open.dmg"
STAGE="$ROOT/build/dmg-stage"
IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: NAN DING (B9UWL2G7ZM)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-notary}"
SKIP_NOTARY="${SKIP_NOTARY:-0}"

"$ROOT/scripts/build-app.sh" release

# Re-sign with Developer ID + Hardened Runtime required for notarization.
codesign --force --deep --options runtime --timestamp \
  --sign "$IDENTITY" \
  --identifier app.agenthud.open \
  "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
echo "Signed: $APP_DIR" >&2

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

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  cat >&2 <<EOF
No notary credentials for profile "$NOTARY_PROFILE".
Create an app-specific password at https://appleid.apple.com then run:

  xcrun notarytool store-credentials "$NOTARY_PROFILE" \\
    --apple-id "YOUR_APPLE_ID" --team-id "B9UWL2G7ZM" --password "app-specific-password"

Then re-run: $0
EOF
  exit 2
fi

xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl -a -t open --context context:primary-signature -v "$DMG" || true
echo "Notarized: $DMG" >&2

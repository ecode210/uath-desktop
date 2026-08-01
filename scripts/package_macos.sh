#!/usr/bin/env bash
# Build and package UATH NFC Bridge for macOS.
# Output: dist/UATH-NFC-Bridge-macos-<version>.zip and .dmg
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(grep '^version:' pubspec.yaml | head -1 | awk '{print $2}' | cut -d'+' -f1)"
APP_NAME="UATH NFC Bridge"
BUNDLE_NAME="UATHNFCBridge.app"
OUT_DIR="$ROOT/dist"
STAGE="$OUT_DIR/macos_stage"

echo "==> flutter build macos --release"
flutter build macos --release

BUILT="$ROOT/build/macos/Build/Products/Release/$BUNDLE_NAME"
if [[ ! -d "$BUILT" ]]; then
  echo "error: expected app at $BUILT" >&2
  exit 1
fi

rm -rf "$STAGE"
mkdir -p "$STAGE" "$OUT_DIR"
cp -R "$BUILT" "$STAGE/$APP_NAME.app"
ln -sf /Applications "$STAGE/Applications"

ZIP_PATH="$OUT_DIR/UATH-NFC-Bridge-macos-$VERSION.zip"
DMG_PATH="$OUT_DIR/UATH-NFC-Bridge-macos-$VERSION.dmg"
rm -f "$ZIP_PATH" "$DMG_PATH"

echo "==> zip"
(
  cd "$STAGE"
  ditto -c -k --sequesterRsrc --keepParent "$APP_NAME.app" "$ZIP_PATH"
)

echo "==> dmg"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

# Ad-hoc sign the packaged app copy for Gatekeeper friendliness on the build machine.
# For distributing outside your org, sign with a Developer ID and notarize.
codesign --force --deep --sign - "$STAGE/$APP_NAME.app" 2>/dev/null || true

rm -rf "$STAGE"

echo ""
echo "macOS packages ready:"
echo "  $ZIP_PATH"
echo "  $DMG_PATH"
echo ""
echo "Install: open the DMG → drag \"$APP_NAME\" to Applications."
echo "If macOS blocks it: right-click the app → Open (first launch)."

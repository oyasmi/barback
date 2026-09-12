#!/bin/bash
# Signs with a Developer ID, notarizes, and staples (design.md §8.5, SEC-5).
# Requires: DEVELOPER_ID_APPLICATION env var (e.g. "Developer ID Application: Name (TEAMID)")
# and a notarytool keychain profile named "barback-notary" (`xcrun notarytool store-credentials`).
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Barback"
APP_BUNDLE=".build/apple/$APP_NAME.app"
DMG_PATH=".build/apple/$APP_NAME.dmg"

: "${DEVELOPER_ID_APPLICATION:?Set DEVELOPER_ID_APPLICATION to your signing identity}"

echo "==> Signing app bundle (Hardened Runtime)"
codesign --force --deep --options runtime \
  --entitlements Resources/Barback.entitlements \
  --sign "$DEVELOPER_ID_APPLICATION" \
  "$APP_BUNDLE"

codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

if [ -f "$DMG_PATH" ]; then
  echo "==> Submitting for notarization"
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "barback-notary" --wait
  echo "==> Stapling"
  xcrun stapler staple "$DMG_PATH"
else
  echo "No .dmg found; run Scripts/package.sh first" >&2
  exit 1
fi

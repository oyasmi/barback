#!/bin/bash
# Signs with a Developer ID, notarizes, and staples (design.md §8.5, SEC-5).
# Requires: DEVELOPER_ID_APPLICATION env var (e.g. "Developer ID Application: Name (TEAMID)")
# and a notarytool keychain profile named "barback-notary" (`xcrun notarytool store-credentials`).
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/_common.sh

: "${DEVELOPER_ID_APPLICATION:?Set DEVELOPER_ID_APPLICATION to your signing identity}"

if [ ! -d "$APP_BUNDLE" ]; then
  echo "$APP_BUNDLE not found — run Scripts/build.sh first (with matching \$ARCHS)" >&2
  exit 1
fi

echo "==> Signing app bundle (Hardened Runtime) — replaces build.sh's ad-hoc signature"
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
  echo "$DMG_PATH not found; run Scripts/package.sh first" >&2
  exit 1
fi

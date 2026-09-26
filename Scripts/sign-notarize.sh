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

# `Scripts/package.sh` was run once already, by `make all` before this script — but that DMG
# wraps the app bundle as `build.sh` ad-hoc-signed it, not the Developer ID signature just
# applied above. Notarizing that DMG unmodified would submit the pre-signing copy: repackage
# now, from the app this script just actually signed, so what gets submitted (and later
# stapled and shipped) is the same bytes that were verified above (R07).
echo "==> Repackaging DMG from the signed app"
Scripts/package.sh

echo "==> Submitting for notarization"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "barback-notary" --wait
echo "==> Stapling"
xcrun stapler staple "$DMG_PATH"

echo "==> Verifying stapled DMG"
xcrun stapler validate "$DMG_PATH"

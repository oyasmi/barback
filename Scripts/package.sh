#!/bin/bash
# Packages Barback.app into a .dmg (design.md §8.5).
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/_common.sh

if [ ! -d "$APP_BUNDLE" ]; then
  echo "$APP_BUNDLE not found — run Scripts/build.sh first (with matching \$ARCHS)" >&2
  exit 1
fi

rm -f "$DMG_PATH"
hdiutil create -volname "$APP_NAME" -srcfolder "$APP_BUNDLE" -ov -format UDZO "$DMG_PATH"
echo "==> Created $DMG_PATH"

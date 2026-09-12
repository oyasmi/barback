#!/bin/bash
# Packages Barback.app into a .dmg (design.md §8.5).
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Barback"
APP_BUNDLE=".build/apple/$APP_NAME.app"
DMG_PATH=".build/apple/$APP_NAME.dmg"

if [ ! -d "$APP_BUNDLE" ]; then
  echo "Run Scripts/build.sh first" >&2
  exit 1
fi

rm -f "$DMG_PATH"
hdiutil create -volname "$APP_NAME" -srcfolder "$APP_BUNDLE" -ov -format UDZO "$DMG_PATH"
echo "==> Created $DMG_PATH"

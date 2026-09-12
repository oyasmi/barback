#!/bin/bash
# Builds the Universal 2 release binary and assembles Barback.app (design.md §8.5).
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Barback"
DIST_DIR="dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"

echo "==> Building Universal 2 release binary"
swift build -c release --arch arm64 --arch x86_64

BIN_PATH=".build/apple/Products/Release/BarbackApp"
if [ ! -f "$BIN_PATH" ]; then
  # SwiftPM's universal binary output path varies by toolchain version; fall back to lipo.
  swift build -c release --arch arm64 --product BarbackApp
  swift build -c release --arch x86_64 --product BarbackApp
  mkdir -p "$(dirname "$BIN_PATH")"
  lipo -create \
    ".build/arm64-apple-macosx/release/BarbackApp" \
    ".build/x86_64-apple-macosx/release/BarbackApp" \
    -output "$BIN_PATH"
fi

echo "==> Assembling app bundle"
mkdir -p "$DIST_DIR"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP_BUNDLE/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
if [ -d Resources/Assets.xcassets ]; then
  cp -R Resources/Assets.xcassets "$APP_BUNDLE/Contents/Resources/"
fi

echo "==> Built $APP_BUNDLE"

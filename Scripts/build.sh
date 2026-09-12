#!/bin/bash
# Builds the release binary and assembles Barback.app (design.md §8.5).
# arm64-only by default; override with `ARCHS="arm64 x86_64" Scripts/build.sh`
# for a Universal 2 build if Intel support is ever needed again.
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/_common.sh

ARCH_FLAGS=()
for arch in $ARCHS; do
  ARCH_FLAGS+=(--arch "$arch")
done

echo "==> Building release binary for: $ARCHS"
swift build -c release "${ARCH_FLAGS[@]}"

# SwiftPM's multi-arch output path varies by toolchain/build-system version; try the
# known locations before falling back to building each arch separately and lipo-ing them.
BIN_PATH=""
for candidate in \
  ".build/apple/Products/Release/BarbackApp" \
  ".build/release/BarbackApp" \
  ".build/arm64-apple-macosx/release/BarbackApp" \
  ".build/x86_64-apple-macosx/release/BarbackApp"
do
  if [ -f "$candidate" ]; then BIN_PATH="$candidate"; break; fi
done

if [ -z "$BIN_PATH" ]; then
  echo "==> Falling back to per-arch build + lipo"
  SLICES=()
  for arch in $ARCHS; do
    swift build -c release --arch "$arch" --product BarbackApp
    SLICES+=(".build/$arch-apple-macosx/release/BarbackApp")
  done
  BIN_PATH=".build/lipo/BarbackApp"
  mkdir -p "$(dirname "$BIN_PATH")"
  if [ "${#SLICES[@]}" -eq 1 ]; then
    cp "${SLICES[0]}" "$BIN_PATH"
  else
    lipo -create "${SLICES[@]}" -output "$BIN_PATH"
  fi
fi

echo "==> Assembling app bundle: $APP_BUNDLE"
mkdir -p "$DIST_DIR"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP_BUNDLE/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
if [ -d Resources/Assets.xcassets ]; then
  cp -R Resources/Assets.xcassets "$APP_BUNDLE/Contents/Resources/"
fi

# Apple Silicon's kernel enforces that every executed Mach-O carry a signature — even an
# ad-hoc one (`-s -`). Without this the bundle launches to "app is damaged or incomplete"
# (Gatekeeper's generic message for "no usable signature", not actual corruption).
# `Scripts/sign-notarize.sh` replaces this with a real Developer ID signature for release.
echo "==> Ad-hoc signing (replace with Scripts/sign-notarize.sh for distribution)"
codesign --force --deep --sign - "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

echo "==> Built $APP_BUNDLE"

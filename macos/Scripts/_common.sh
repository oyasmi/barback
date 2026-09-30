# Shared by build.sh / package.sh / sign-notarize.sh so all three agree on names.
#
# The bundle is always named plain "Barback.app": macOS's Login Items UI (System
# Settings, via SMAppService) displays the .app bundle's own filename, not
# CFBundleDisplayName — an arch-tagged filename like "Barback-arm64-x86_64.app"
# would leak into that UI verbatim, which is confusing for end users.
APP_NAME="Barback"
DIST_DIR="dist"

# arm64-only by default (Apple Silicon); override with e.g.
# `ARCHS="arm64 x86_64" Scripts/build.sh` if Intel support is ever needed again.
ARCHS="${ARCHS:-arm64}"

APP_BUNDLE="$DIST_DIR/$APP_NAME.app"

# The .dmg filename (unlike the .app bundle name above) is safe to tag with
# arch/version since it's just a downloaded artifact, not something macOS
# surfaces as a persistent label — and doing so avoids clobbering older
# builds when comparing downloads.
APP_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
DMG_ARCH_TAG="${ARCHS// /-}"
DMG_PATH="$DIST_DIR/$APP_NAME-$APP_VERSION-$DMG_ARCH_TAG.dmg"

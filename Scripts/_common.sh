# Shared by build.sh / package.sh / sign-notarize.sh so all three agree on the
# artifact name (which is derived from $ARCHS, so a single-arch debug/local build
# doesn't get confused with the universal release one).
APP_NAME="Barback"
DIST_DIR="dist"

# Override with e.g. `ARCHS="arm64" Scripts/build.sh` for an arm64-only build.
ARCHS="${ARCHS:-arm64 x86_64}"
ARCH_TAG="$(echo "$ARCHS" | tr ' ' '\n' | sort | paste -sd '-' -)"

APP_BUNDLE="$DIST_DIR/$APP_NAME-$ARCH_TAG.app"
DMG_PATH="$DIST_DIR/$APP_NAME-$ARCH_TAG.dmg"

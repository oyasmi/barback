.PHONY: all build test run sign clean

# Default: build dist/Barback.app and dist/Barback-<version>-<arch>.dmg (arm64, design.md §8.5).
all:
	Scripts/build.sh
	Scripts/package.sh

# Debug build of everything (library + app + test fixtures) — for development only.
build:
	swift build

# Full test suite: pure state-machine unit tests + real-process integration tests.
test:
	swift test

# Run the app directly from the debug build (dev only: no .app bundle, so system
# notifications and the login item are unavailable — see README "已知限制").
run:
	swift run BarbackApp

# Sign (Developer ID + Hardened Runtime), notarize and staple the dist/*.dmg.
# Requires DEVELOPER_ID_APPLICATION to be set in the environment.
# `all`'s own package.sh run only produces the ad-hoc-signed DMG build.sh needs to exist at
# all — sign-notarize.sh repackages it itself from the Developer ID–signed app before
# submitting, so what gets notarized/stapled is never the pre-signing copy (R07).
sign: all
	Scripts/sign-notarize.sh

clean:
	swift package clean
	rm -rf .build dist

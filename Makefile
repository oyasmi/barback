.PHONY: all build test run sign clean

# Default: build dist/Barback.app and dist/Barback.dmg (arm64, design.md §8.5).
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

# Sign (Developer ID + Hardened Runtime) and notarize dist/Barback.dmg.
# Requires DEVELOPER_ID_APPLICATION to be set in the environment.
sign: all
	Scripts/sign-notarize.sh

clean:
	swift package clean
	rm -rf .build dist

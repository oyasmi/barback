.PHONY: build release test run clean app package sign lint

# Debug build of everything (library + app + test fixtures).
build:
	swift build

# Release build of the BarbackApp executable for the host architecture only.
release:
	swift build -c release --product BarbackApp

# Full test suite: pure state-machine unit tests + real-process integration tests.
test:
	swift test

# Run the app directly from the build dir (dev only: no .app bundle, so system
# notifications and the login item are unavailable — see README "已知限制").
run:
	swift run BarbackApp

# Universal 2 release build + assemble Barback.app (design.md §8.5).
app:
	Scripts/build.sh

# Package the built Barback.app into a .dmg. Requires `make app` first.
package: app
	Scripts/package.sh

# Sign (Developer ID + Hardened Runtime) and notarize the .dmg from `make package`.
# Requires DEVELOPER_ID_APPLICATION to be set in the environment.
sign: package
	Scripts/sign-notarize.sh

clean:
	swift package clean
	rm -rf .build

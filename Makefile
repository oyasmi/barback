# Compatibility entry point. Platform-specific build logic lives in macos/.
.PHONY: all build test run sign clean
all build test run sign clean:
	$(MAKE) -C macos $@

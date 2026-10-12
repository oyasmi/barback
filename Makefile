# Compatibility entry point. Platform-specific build logic lives in macos/.
.PHONY: all build test run check-strings sign clean
all build test run check-strings sign clean:
	$(MAKE) -C macos $@

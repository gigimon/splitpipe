BUILD_DIR := build
APP := $(BUILD_DIR)/Build/Products/Debug/SplitPipe.app
# The extension version changes only when its code changed: every new version makes the system replace the extension,
# stopping the proxy and dropping all intercepted connections. With git — the time of the last commit touching the
# extension code (mtime after checkout or copying is arbitrary, the version could "go down"); without git or with
# uncommitted changes there — the newest file mtime.
EXTENSION_VERSION := $(shell \
	if git rev-parse --git-dir >/dev/null 2>&1 && git diff --quiet HEAD -- SplitPipeProxy Shared 2>/dev/null \
		&& [ -n "$$(git log -1 --format=%ct -- SplitPipeProxy Shared)" ]; then \
		git log -1 --format=%ct -- SplitPipeProxy Shared; \
	else \
		find SplitPipeProxy Shared -type f -exec stat -f %m {} + | sort -n | tail -1; \
	fi)

# App version from git tags, shown in Settings → About (scripts/resolve_version.sh).
APP_VERSION := $(shell bash -c 'source scripts/resolve_version.sh && echo $$APP_VERSION')

.PHONY: project build test package install run logs clean

project:
	xcodegen generate

build: project
	xcodebuild -project SplitPipe.xcodeproj -scheme SplitPipe -configuration Debug \
		-derivedDataPath $(BUILD_DIR) -allowProvisioningUpdates \
		MARKETING_VERSION=$(APP_VERSION) CURRENT_PROJECT_VERSION=$(shell date +%s) EXTENSION_VERSION=$(EXTENSION_VERSION) build

# Pure logic without network: parsing routing socket messages, IPv6 routes, STUN, rule matching.
test: project
	xcodebuild -project SplitPipe.xcodeproj -scheme SplitPipeTests -configuration Debug \
		-derivedDataPath $(BUILD_DIR) test

# Unsigned Release archive in build/release, version from git tags (scripts/resolve_version.sh).
package:
	EXTENSION_VERSION=$(EXTENSION_VERSION) scripts/package.sh

install: build
	-osascript -e 'quit app "SplitPipe"'
	rm -rf /Applications/SplitPipe.app
	cp -R $(APP) /Applications/

run: install
	open /Applications/SplitPipe.app

logs:
	log stream --level info --predicate 'subsystem == "dev.splitpipe"'

clean:
	rm -rf $(BUILD_DIR) SplitPipe.xcodeproj

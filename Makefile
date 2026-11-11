.PHONY: release dev clean sync-mounts

# Supported platforms: pak.json is the single source of truth. The per-device test targets
# (test-device-<platform>) and the device settings are generated from this list, so a new
# platform in pak.json needs no change here.
PLATFORMS := $(shell jq -r '.platforms[]' pak.json)
comma := ,
empty :=
space := $(empty) $(empty)
platform_upper = $(shell printf '%s' '$(1)' | tr '[:lower:]' '[:upper:]')

# Device settings (<PLATFORM>_HOST, optional <PLATFORM>_SSH_OPTS). tests/devices.env is
# git-ignored; copy tests/devices.env.example. It only uses "?=", so values from the command
# line or the environment take precedence.
-include tests/devices.env
DEVICE_VARS := $(foreach p,$(PLATFORMS),$(call platform_upper,$(p))_HOST $(call platform_upper,$(p))_SSH_OPTS)
export $(DEVICE_VARS)

ARCHIVE := dist/RetroArch Core Saves.pak.zip
PACKAGE := RetroArch Core Saves.pak
MOUNT_MANAGER := ../mount-manager

release:
	mkdir -p dist
	rm -f "$(ARCHIVE)"
	git archive --worktree-attributes --format=zip \
		--output="$(ARCHIVE)" HEAD

dev:
	mkdir -p dist
	rm -f "$(ARCHIVE)"
	zip -q -r "$(notdir $(ARCHIVE))" . \
		-x "/.git" \
		-x "/.git/*" \
		-x "/bin/desktop" \
		-x "/bin/desktop/*" \
		-x "/bin/tests" \
		-x "/bin/tests/*" \
		-x "/tests" \
		-x "/tests/*" \
		-x "/.github" \
		-x "/.github/*" \
		-x "/__pycache__" \
		-x "/__pycache__/*" \
		-x "/bin/SHA256SUMS" \
		-x "/dist/*" \
		-x "/screenshots/*" \
		-x "/Makefile" \
		-x "/docs" \
		-x "/docs/*" \
		-x "/Findings.md" \
		-x "/.gitignore" \
		-x "/.gitattributes" \
		-x "/RetroArch Core Saves.pak.zip"

# --- tests ---------------------------------------------------------------------------
# Test framework: bats-core and its helper libraries, downloaded at pinned versions into
# tests/lib (git-ignored).
BATS_CORE_VERSION := 1.11.1
BATS_SUPPORT_VERSION := 0.3.0
BATS_ASSERT_VERSION := 2.1.0
BATS_GITHUB_URL := https://github.com/bats-core

tests/lib/bats-core/bin/bats:
	mkdir -p tests/lib/bats-core
	curl -f -o tests/lib/bats-core.tar.gz -sSL $(BATS_GITHUB_URL)/bats-core/archive/refs/tags/v$(BATS_CORE_VERSION).tar.gz
	tar -xzf tests/lib/bats-core.tar.gz --strip-components=1 -C tests/lib/bats-core
	rm -f tests/lib/bats-core.tar.gz

tests/lib/bats-support/load.bash:
	mkdir -p tests/lib/bats-support
	curl -f -o tests/lib/bats-support.tar.gz -sSL $(BATS_GITHUB_URL)/bats-support/archive/refs/tags/v$(BATS_SUPPORT_VERSION).tar.gz
	tar -xzf tests/lib/bats-support.tar.gz --strip-components=1 -C tests/lib/bats-support
	rm -f tests/lib/bats-support.tar.gz

tests/lib/bats-assert/load.bash:
	mkdir -p tests/lib/bats-assert
	curl -f -o tests/lib/bats-assert.tar.gz -sSL $(BATS_GITHUB_URL)/bats-assert/archive/refs/tags/v$(BATS_ASSERT_VERSION).tar.gz
	tar -xzf tests/lib/bats-assert.tar.gz --strip-components=1 -C tests/lib/bats-assert
	rm -f tests/lib/bats-assert.tar.gz

BATS_DEPS := tests/lib/bats-core/bin/bats tests/lib/bats-support/load.bash tests/lib/bats-assert/load.bash

# make test                      tests tagged "host": runs on the host and in CI, never uses ssh
# make test-device               on-device tests (tagged "device") on every configured device
# make test-device-<platform>    one device (generated for every platform in pak.json)
# Every run writes dist/test-report-<target>-<timestamp>.tar.gz (see README.md).
#
# By default the repository checkout is tested. SRC_PAK=<dir> tests an unpacked release
# instead, RELEASE_ZIP=<zip> checks that release archive's contents (CI does both).
.PHONY: test test-device test-bundle $(addprefix test-device-,$(PLATFORMS))

test: $(BATS_DEPS)
	MAKE_VARS="PAK_NAME=$(shell jq -r .name pak.json) PLATFORMS=$(subst $(space),$(comma),$(PLATFORMS)) SRC_PAK=$(SRC_PAK) RELEASE_ZIP=$(RELEASE_ZIP) MAKECMDGOALS=$(MAKECMDGOALS)" \
		bash tests/run-host.sh

CONFIGURED_PLATFORMS := $(strip $(foreach p,$(PLATFORMS),$(if $(strip $($(call platform_upper,$(p))_HOST)),$(p))))

test-device: $(if $(CONFIGURED_PLATFORMS),test-bundle)
	@fail=0; for p in $(PLATFORMS); do \
		MAKE_VARS="PLATFORMS=$(subst $(space),$(comma),$(PLATFORMS)) MAKECMDGOALS=$(MAKECMDGOALS)" \
			bash tests/run-device.sh "$$p" --skip-unconfigured || fail=1; \
	done; exit $$fail

.SECONDEXPANSION:
$(addprefix test-device-,$(PLATFORMS)): test-device-%: $$(if $$(strip $$($$(call platform_upper,$$*)_HOST)),test-bundle)
	MAKE_VARS="PLATFORMS=$(subst $(space),$(comma),$(PLATFORMS)) MAKECMDGOALS=$(MAKECMDGOALS)" \
		bash tests/run-device.sh "$*"

# Everything needed to run the on-device tests; run-device.sh streams it to the device.
# bin/tests holds the sh suites (not part of a release); pak.json names the pak.
test-bundle: $(BATS_DEPS)
	mkdir -p dist
	tar -czf dist/pak-device-tests.tar.gz \
		--exclude='tests/lib/*/test' --exclude='tests/lib/*/docs' --exclude='tests/lib/*/man' \
		tests/bats tests/helpers tests/lib tests/run-bats.sh tests/collect.sh tests/collectors \
		bin/tests pak.json
	ls -lah dist

# bin/mounts/mountctl.sh is a copy of ../mount-manager, shared with Profiles.pak.
# 20-core-saves.sh is this pak's own layer (it also mounts Core States) and is
# maintained here, so it is not synced.
sync-mounts:
	mkdir -p bin/mounts
	cp $(MOUNT_MANAGER)/mountctl.sh bin/mounts/
	chmod 0755 bin/mounts/*.sh

clean:
	rm -f "$(ARCHIVE)" dist/pak-device-tests.tar.gz dist/test-report-*.tar.gz
	rm -rf tests/lib dist/test-out

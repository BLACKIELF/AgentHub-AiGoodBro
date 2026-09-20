APP_NAME := AiGoodBro
LEGACY_APP_NAME := CodexAccountManagerNext
DISPLAY_NAME := AiGoodBro
VERSION := $(shell /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist 2>/dev/null || echo 0.1.0)
BUILD_DIR := build
DIST_DIR := dist
APP_DIR := $(BUILD_DIR)/$(APP_NAME).app
MACOS_DIR := $(APP_DIR)/Contents/MacOS
RESOURCES_DIR := $(APP_DIR)/Contents/Resources
SOURCES := $(shell find Sources/CodexUsageWidget -name '*.swift' | sort)
APP_ICON_SOURCE := Resources/AiGoodBro.icns
APP_ICON := AiGoodBro.icns
RUNTIME_PNG_RESOURCES := Resources/AiGoodBro-icon.png Resources/codex-color.png Resources/codex-template.png Resources/claudecode-color.png Resources/claudecode-template.png
ICON_VARIANTS := Resources/AiGoodBro-02-deep-plum.icns Resources/AiGoodBro-03-sage-green.icns Resources/AiGoodBro-04-graphite.icns Resources/AiGoodBro-05-champagne.icns
LEADERSHIP_BADGES := $(sort $(wildcard Resources/LeadershipBadges/leadership-badge-l*.png))
SELF_TEST_RUNNER := ./scripts/run-self-tests.sh
DEPLOYMENT_TARGET ?= 13.0
HOST_ARCH := $(shell uname -m)
APPLE_SILICON_TARGET_TRIPLE ?= arm64-apple-macos$(DEPLOYMENT_TARGET)
INTEL_TARGET_TRIPLE ?= x86_64-apple-macos$(DEPLOYMENT_TARGET)
TARGET_TRIPLE ?= $(HOST_ARCH)-apple-macos$(DEPLOYMENT_TARGET)
ARCH_NAME := $(shell echo "$(TARGET_TRIPLE)" | sed -E 's/-apple-macos.*//')
DMG_NAME := $(APP_NAME)-$(VERSION)-mac-$(ARCH_NAME).dmg
DMG_PATH := $(DIST_DIR)/$(DMG_NAME)
SIGN_IDENTITY ?= -
BUNDLE_COMPANION ?= 1
TOKEN_MONITOR_CACHE ?= $(HOME)/Library/Caches/AiGoodBro/Next/token-monitor-downloads
TOKEN_MONITOR_RECEIPT_DIR ?= .build-receipts/AiGoodBro/Next
TOKEN_MONITOR_RECEIPT = $(TOKEN_MONITOR_RECEIPT_DIR)/token-monitor-$(ARCH_NAME).json
TOKEN_MONITOR_OFFLINE ?= 0
TOKEN_MONITOR_NODE_ARCHIVE ?=
CODESIGN_EXTRA_FLAGS ?=
ACTIVE_DEVELOPER_DIR := $(shell xcode-select -p 2>/dev/null)
DEFAULT_SDK_PATH := $(shell xcrun --sdk macosx --show-sdk-path 2>/dev/null)
CLT_COMPAT_SDK := $(firstword $(wildcard /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk))
ifeq ($(ACTIVE_DEVELOPER_DIR),/Library/Developer/CommandLineTools)
SDK_PATH ?= $(if $(CLT_COMPAT_SDK),$(CLT_COMPAT_SDK),$(DEFAULT_SDK_PATH))
else
SDK_PATH ?= $(DEFAULT_SDK_PATH)
endif
MODULE_CACHE_PATH ?= $(BUILD_DIR)/ModuleCache
SWIFTC_TARGET_FLAGS := -target $(TARGET_TRIPLE) -sdk $(SDK_PATH) -module-cache-path $(MODULE_CACHE_PATH)
SWIFT_OPTIMIZATION ?= -O
SWIFTC_PARALLELISM ?= -j 4
MACOS_SDK_MAJOR := $(shell /usr/libexec/PlistBuddy -c "Print Version" "$(SDK_PATH)/SDKSettings.plist" 2>/dev/null | cut -d. -f1)
SWIFTC_FEATURE_FLAGS :=

ifeq ($(shell test "$(MACOS_SDK_MAJOR)" -ge 26 2>/dev/null && echo yes),yes)
SWIFTC_FEATURE_FLAGS += -D CAMNEXT_HAS_LIQUID_GLASS
endif

ifeq ($(SIGN_IDENTITY),-)
CODESIGN_FLAGS := --force --deep --sign -
else
CODESIGN_FLAGS := --force --deep --options runtime --timestamp --sign "$(SIGN_IDENTITY)" $(CODESIGN_EXTRA_FLAGS)
endif

POWERSHELL ?= powershell.exe
SWIFT_FORMAT ?= xcrun swift-format

.PHONY: build debug run probe lint test verify-runtime-resources test-rate-limits test-statistics-time-zone test-token-counter test-model-pricing test-model-usage-trend test-model-inference-performance test-app-server-pipe test-cc-switch test-profile-store test-account-inspection test-automatic-account-switch test-feishu-webhook test-account-automation-audit test-account-switch-safety test-task-runtime test-leadership-model test-leadership-assets test-codex-session-link test-performance-monitor test-phase-one-gate test-particle-animation test-palettes test-macos-compatibility memory-risk-check phase-one-check phase-one-soak install dmg dmg-arm64 dmg-intel checksum checksum-arm64 checksum-intel release release-arm64 release-intel release-all release-package release-windows release-cross-platform-check release-check notarize verify clean clean-dist

build:
	@if [ -e "$(MACOS_DIR)/$(APP_NAME)" ]; then \
		python3 scripts/check-build-target-idle.py "$(MACOS_DIR)/$(APP_NAME)"; \
	fi
	rm -rf "$(APP_DIR)"
	mkdir -p "$(MACOS_DIR)" "$(RESOURCES_DIR)"
	cp Resources/Info.plist "$(APP_DIR)/Contents/Info.plist"
	cp "$(APP_ICON_SOURCE)" "$(RESOURCES_DIR)/$(APP_ICON)"
	cp $(ICON_VARIANTS) "$(RESOURCES_DIR)/"
	cp $(RUNTIME_PNG_RESOURCES) "$(RESOURCES_DIR)/"
	cp Resources/THIRD_PARTY_NOTICES.txt "$(RESOURCES_DIR)/"
	cp docs/third-party-cli-notices.md "$(RESOURCES_DIR)/CLI_PROVIDER_NOTICES.md"
	cp -R Resources/Palettes "$(RESOURCES_DIR)/Palettes"
	cp -R Resources/SkillLibrary "$(RESOURCES_DIR)/SkillLibrary"
	mkdir -p "$(RESOURCES_DIR)/UpstreamCharts"
	cp -R Resources/UpstreamCharts/ "$(RESOURCES_DIR)/UpstreamCharts/"
	/usr/bin/xattr -dr com.apple.quarantine "$(APP_DIR)" 2>/dev/null || true
	MACOSX_DEPLOYMENT_TARGET="$(DEPLOYMENT_TARGET)" swiftc $(SWIFT_OPTIMIZATION) $(SWIFTC_PARALLELISM) -parse-as-library $(SWIFTC_TARGET_FLAGS) $(SWIFTC_FEATURE_FLAGS) $(SOURCES) \
		-o "$(MACOS_DIR)/$(APP_NAME)" \
		-framework Cocoa \
		-framework Carbon \
		-framework Security \
		-framework SwiftUI \
		-framework UserNotifications
	python3 scripts/prepare-companion-resources.py --resources "$(RESOURCES_DIR)" --arch "$(ARCH_NAME)" --sign-identity "$(SIGN_IDENTITY)" $(if $(filter 1,$(BUNDLE_COMPANION)),--include-hub,)
	python3 scripts/prepare-token-monitor-resources.py --resources "$(RESOURCES_DIR)" --arch "$(ARCH_NAME)" --cache "$(TOKEN_MONITOR_CACHE)" --trusted-receipt "$(TOKEN_MONITOR_RECEIPT)" --sign-identity "$(SIGN_IDENTITY)" $(if $(filter 1,$(TOKEN_MONITOR_OFFLINE)),--offline,) $(if $(TOKEN_MONITOR_NODE_ARCHIVE),--node-archive "$(TOKEN_MONITOR_NODE_ARCHIVE)",)
	codesign $(filter-out --deep,$(CODESIGN_FLAGS)) "$(APP_DIR)"
	codesign --verify --deep --strict "$(APP_DIR)"
	python3 scripts/prepare-token-monitor-resources.py --verify --resources "$(RESOURCES_DIR)" --bundle "$(APP_DIR)" --sign-identity "$(SIGN_IDENTITY)" --arch "$(ARCH_NAME)" --cache "$(TOKEN_MONITOR_CACHE)" --trusted-receipt "$(TOKEN_MONITOR_RECEIPT)"

debug:
	$(MAKE) build BUILD_DIR=build-debug SWIFT_OPTIMIZATION=-Onone

run: build
	open "$(APP_DIR)"

probe: build
	"$(MACOS_DIR)/$(APP_NAME)" --dump-json

lint:
	$(SWIFT_FORMAT) lint --strict --parallel --recursive --configuration .swift-format Sources/CodexUsageWidget

verify-runtime-resources:
	@python3 scripts/prepare-companion-resources.py --verify --resources "$(RESOURCES_DIR)" --arch "$(ARCH_NAME)" $(if $(filter 1,$(BUNDLE_COMPANION)),--include-hub,)
	@for resource in $(RUNTIME_PNG_RESOURCES); do \
		bundled="$(RESOURCES_DIR)/$$(basename "$$resource")"; \
		test -s "$$bundled" || { echo "missing runtime resource: $$bundled"; exit 1; }; \
		cmp -s "$$resource" "$$bundled" || { echo "runtime resource differs from source: $$bundled"; exit 1; }; \
	done
	@echo "Verified $(words $(RUNTIME_PNG_RESOURCES)) runtime PNG resources"

test: build
	@$(MAKE) --no-print-directory verify-runtime-resources BUILD_DIR="$(BUILD_DIR)"
	$(SELF_TEST_RUNNER) --skip-build --build-dir "$(BUILD_DIR)"
	python3 scripts/test-dispatch-participation.py --tests-only

test-rate-limits:
	./scripts/test-rate-limits.sh

test-statistics-time-zone:
	./scripts/test-statistics-time-zone.sh

test-token-counter: build
	$(SELF_TEST_RUNNER) --skip-build --build-dir "$(BUILD_DIR)" --only token-counter

test-model-pricing: build
	$(SELF_TEST_RUNNER) --skip-build --build-dir "$(BUILD_DIR)" --only model-pricing

test-model-usage-trend: build
	$(SELF_TEST_RUNNER) --skip-build --build-dir "$(BUILD_DIR)" --only model-usage-trend

test-model-inference-performance: build
	$(SELF_TEST_RUNNER) --skip-build --build-dir "$(BUILD_DIR)" --only model-inference-performance

test-app-server-pipe: build
	$(SELF_TEST_RUNNER) --skip-build --build-dir "$(BUILD_DIR)" --only app-server-pipe

test-cc-switch: build
	$(SELF_TEST_RUNNER) --skip-build --build-dir "$(BUILD_DIR)" --only cc-switch

test-profile-store: build
	$(SELF_TEST_RUNNER) --skip-build --build-dir "$(BUILD_DIR)" --only profile-store

test-account-inspection: build
	$(SELF_TEST_RUNNER) --skip-build --build-dir "$(BUILD_DIR)" --only account-inspection

test-automatic-account-switch: build
	$(SELF_TEST_RUNNER) --skip-build --build-dir "$(BUILD_DIR)" --only automatic-account-switch

test-feishu-webhook: build
	$(SELF_TEST_RUNNER) --skip-build --build-dir "$(BUILD_DIR)" --only feishu-webhook

test-account-automation-audit: build
	$(SELF_TEST_RUNNER) --skip-build --build-dir "$(BUILD_DIR)" --only account-automation-audit

test-account-switch-safety: build
	$(SELF_TEST_RUNNER) --skip-build --build-dir "$(BUILD_DIR)" --only account-switch-safety

test-task-runtime: build
	$(SELF_TEST_RUNNER) --skip-build --build-dir "$(BUILD_DIR)" --only task-runtime

test-leadership-model: build
	$(SELF_TEST_RUNNER) --skip-build --build-dir "$(BUILD_DIR)" --only leadership-model

test-leadership-assets:
	@test "$(words $(LEADERSHIP_BADGES))" -eq 7 || { echo "expected 7 leadership badge PNGs"; exit 1; }
	@for badge in $(LEADERSHIP_BADGES); do \
		width=$$(sips -g pixelWidth "$$badge" | awk '/pixelWidth/ { print $$2 }'); \
		height=$$(sips -g pixelHeight "$$badge" | awk '/pixelHeight/ { print $$2 }'); \
		alpha=$$(sips -g hasAlpha "$$badge" | awk '/hasAlpha/ { print $$2 }'); \
		test "$$width" -ge 1024 -a "$$height" -ge 1024 -a "$$alpha" = yes || { echo "invalid leadership badge: $$badge ($$width x $$height, alpha=$$alpha)"; exit 1; }; \
	done

test-codex-session-link: build
	$(SELF_TEST_RUNNER) --skip-build --build-dir "$(BUILD_DIR)" --only codex-session-link

test-performance-monitor: build
	$(SELF_TEST_RUNNER) --skip-build --build-dir "$(BUILD_DIR)" --only performance-monitor

test-phase-one-gate: build
	$(SELF_TEST_RUNNER) --skip-build --build-dir "$(BUILD_DIR)" --only phase-one-gate

test-macos-compatibility:
	./scripts/test-macos-compatibility.sh

test-particle-animation:
	./scripts/test-particle-animation.sh

test-palettes:
	./scripts/test-palettes.sh

memory-risk-check:
	BUILD_DIR="$(BUILD_DIR)" ./scripts/check-memory-risks.sh

phase-one-check: build
	./scripts/phase-one-check.sh

phase-one-soak: build
	./scripts/phase-one-soak.sh

install: build
	@if [ ! -d "$(APP_DIR)" ] || [ ! -x "$(MACOS_DIR)/$(APP_NAME)" ]; then \
		echo "install: staged app bundle is missing or invalid." >&2; \
		exit 1; \
	fi
	@codesign --verify --deep --strict "$(APP_DIR)"
	@dest="/Applications/$(APP_NAME).app"; \
	legacy="/Applications/$(LEGACY_APP_NAME).app"; \
	prev="$$dest.previous"; \
	if [ -e "$$dest" ] && { [ -L "$$dest" ] || [ ! -d "$$dest" ]; }; then \
		echo "install: $$dest exists but is not a real app directory; refusing to replace." >&2; \
		exit 1; \
	fi; \
	if [ -e "$$legacy" ] && { [ -L "$$legacy" ] || [ ! -d "$$legacy" ]; }; then \
		echo "install: $$legacy exists but is not a real app directory; refusing to replace." >&2; \
		exit 1; \
	fi; \
	if [ -d "$$dest" ] && [ -d "$$legacy" ]; then \
		echo "install: both $$dest and $$legacy exist; keep one launchable copy before replacing." >&2; \
		exit 1; \
	fi; \
	if [ -e "$$prev" ] && { [ -d "$$dest" ] || [ -d "$$legacy" ]; }; then \
		echo "install: leftover $$prev exists; refusing to replace." >&2; \
		exit 1; \
	fi; \
	if [ -e "$$prev" ] && { [ -L "$$prev" ] || [ ! -d "$$prev" ]; }; then \
		echo "install: leftover $$prev exists but is not a real app directory; refusing to replace." >&2; \
		exit 1; \
	fi; \
	staging=$$(/usr/bin/mktemp -d "$$dest.staging.XXXXXX") || { \
		echo "install: could not create a unique staging directory." >&2; \
		exit 1; \
	}; \
	if ! cp -R "$(APP_DIR)/." "$$staging"; then \
		rm -rf "$$staging"; \
		echo "install: staging copy failed; the live app was left untouched." >&2; \
		exit 1; \
	fi; \
	if ! codesign --verify --deep --strict "$$staging"; then \
		rm -rf "$$staging"; \
		echo "install: staged copy failed codesign verification; the live app was left untouched." >&2; \
		exit 1; \
	fi; \
	live=""; \
	if [ -d "$$dest" ]; then live="$$dest"; elif [ -d "$$legacy" ]; then live="$$legacy"; fi; \
	if [ -n "$$live" ] && [ ! -f "$$live/Contents/MacOS/$(APP_NAME)" ] && [ ! -f "$$live/Contents/MacOS/$(LEGACY_APP_NAME)" ]; then \
		rm -rf "$$staging"; \
		echo "install: existing app is missing its executable; refusing to replace without an idle check." >&2; \
		exit 1; \
	fi; \
	for bundle in "$$dest" "$$legacy"; do \
		for exe in "$(APP_NAME)" "$(LEGACY_APP_NAME)"; do \
			if [ -f "$$bundle/Contents/MacOS/$$exe" ]; then \
				python3 scripts/check-build-target-idle.py "$$bundle/Contents/MacOS/$$exe" || { \
					rm -rf "$$staging"; \
					exit 1; \
				}; \
			fi; \
		done; \
	done; \
	if [ -d "$$live" ]; then \
		if ! mv "$$live" "$$prev"; then \
			rm -rf "$$staging"; \
			echo "install: could not move the live app aside; it was left in place." >&2; \
			exit 1; \
		fi; \
	fi; \
	if ! mv "$$staging" "$$dest"; then \
		rm -rf "$$staging"; \
		if [ -d "$$prev" ]; then \
			restore="$$dest"; \
			if [ -n "$$live" ] && [ "$$live" = "$$legacy" ]; then restore="$$legacy"; fi; \
			if mv "$$prev" "$$restore" && [ -d "$$restore" ] && [ ! -L "$$restore" ]; then \
				echo "install: promote failed; the previous installation was restored." >&2; \
			else \
				echo "install: promote failed and the previous installation could not be restored at $$restore (left at $$prev)." >&2; \
			fi; \
		else \
			echo "install: promote failed; there was no previous installation to restore." >&2; \
		fi; \
		exit 1; \
	fi; \
	if [ ! -d "$$dest" ] || [ -L "$$dest" ]; then \
		echo "install: promote reported success but $$dest is not a real app directory." >&2; \
		exit 1; \
	fi; \
	if [ -d "$$prev" ]; then \
		rm -rf "$$prev"; \
	fi
	open "/Applications/$(APP_NAME).app"

dmg: build
	APP_NAME="$(APP_NAME)" \
	DISPLAY_NAME="$(DISPLAY_NAME)" \
	VERSION="$(VERSION)" \
	ARCH_NAME="$(ARCH_NAME)" \
	BUILD_DIR="$(BUILD_DIR)" \
	DIST_DIR="$(DIST_DIR)" \
	APP_DIR="$(APP_DIR)" \
	DMG_PATH="$(DMG_PATH)" \
	DMG_SIGN_IDENTITY="$(DMG_SIGN_IDENTITY)" \
	./scripts/package-dmg.sh

dmg-arm64:
	$(MAKE) dmg TARGET_TRIPLE="$(APPLE_SILICON_TARGET_TRIPLE)"

dmg-intel:
	$(MAKE) dmg TARGET_TRIPLE="$(INTEL_TARGET_TRIPLE)"

checksum: dmg
	shasum -a 256 "$(DMG_PATH)" > "$(DMG_PATH).sha256"
	@cat "$(DMG_PATH).sha256"

checksum-arm64:
	$(MAKE) checksum TARGET_TRIPLE="$(APPLE_SILICON_TARGET_TRIPLE)"

checksum-intel:
	$(MAKE) checksum TARGET_TRIPLE="$(INTEL_TARGET_TRIPLE)"

release: clean checksum
	@echo "Release artifact: $(DMG_PATH)"

release-arm64:
	$(MAKE) release TARGET_TRIPLE="$(APPLE_SILICON_TARGET_TRIPLE)"

release-intel:
	$(MAKE) release TARGET_TRIPLE="$(INTEL_TARGET_TRIPLE)"

release-all: clean-dist
	$(MAKE) release-arm64
	$(MAKE) release-intel

release-package: memory-risk-check
	./scripts/build-release-artifacts.sh "$(VERSION)"

release-windows:
	$(POWERSHELL) -NoProfile -ExecutionPolicy Bypass -File scripts/build-windows-release.ps1 -Version "$(VERSION)"

release-cross-platform-check:
	./scripts/check-cross-platform-release-assets.sh "$(VERSION)" "$(DIST_DIR)"

release-check: memory-risk-check
	./scripts/check-release-ready.sh "$(VERSION)"

notarize: dmg
	APPLE_ID="$(APPLE_ID)" \
	TEAM_ID="$(TEAM_ID)" \
	NOTARY_PASSWORD="$(NOTARY_PASSWORD)" \
	DMG_PATH="$(DMG_PATH)" \
	./scripts/notarize-dmg.sh

verify: build
	file "$(MACOS_DIR)/$(APP_NAME)"
	codesign -dv --verbose=4 "$(APP_DIR)"

clean:
	rm -rf "$(BUILD_DIR)"

clean-dist:
	rm -rf "$(DIST_DIR)"

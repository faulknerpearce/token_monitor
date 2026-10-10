# Makefile — TokenMon (macOS Swift / Xcode)
.PHONY: default help tasks build release run install uninstall clean test test-core lint lint-fix format format-fix secrets \
	project icon check open archive export pkg notarize distclean _release-app _stage-dist _zip _dsym

default: help

# Configuration

PROJECT        := TokenMon.xcodeproj
SCHEME         := TokenMon
APP_NAME       := TokenMon
BUNDLE_ID      := com.modelmonitor.app

CONFIGURATION_DEBUG   := Debug
CONFIGURATION_RELEASE := Release

BUILD_DIR      := build
DERIVED_DATA   := $(BUILD_DIR)/DerivedData
DIST_DIR       := dist
ARCHIVE_PATH   := $(BUILD_DIR)/TokenMon.xcarchive
EXPORT_DIR     := $(BUILD_DIR)/export

# Read version from project.yml (fallback if xcodegen / plutil unavailable)
VERSION ?= $(shell sed -n 's/.*MARKETING_VERSION: *"\([^"]*\)".*/\1/p' project.yml 2>/dev/null | head -1)
VERSION := $(if $(VERSION),$(VERSION),1.0.0)

# CFBundleVersion for release builds: the commit count, which only grows on a
# linear master. Falls back to project.yml's CURRENT_PROJECT_VERSION outside git.
BUILD_NUMBER ?= $(shell git rev-list --count HEAD 2>/dev/null)
BUILD_NUMBER_FLAG := $(if $(BUILD_NUMBER),CURRENT_PROJECT_VERSION=$(BUILD_NUMBER),)

# Destination for local install
INSTALL_DIR    ?= /Applications

# Auto-detect Developer ID identities (empty → ad-hoc / unsigned packaging).
# Picks up whichever certs are in the current developer's keychain.
DEVELOPER_ID_APP ?= $(shell security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)
DEVELOPER_ID_INSTALLER ?= $(shell security find-identity -v 2>/dev/null | sed -n 's/.*"\(Developer ID Installer:[^"]*\)".*/\1/p' | head -1)
# Team ID is the (XXXXXXXXXX) suffix on the identity string, when present.
DEVELOPMENT_TEAM ?= $(shell printf '%s' '$(DEVELOPER_ID_APP)' | sed -n 's/.*(\([A-Z0-9]\{10\}\))$$/\1/p')

# Notarytool keychain profile (see Docs/NOTARIZATION.md)
NOTARY_PROFILE ?= AC_PASSWORD

# Colors
CYAN  := \033[36m
GREEN := \033[32m
YELL  := \033[33m
RED   := \033[31m
BOLD  := \033[1m
RESET := \033[0m

define say
	@printf "$(CYAN)→$(RESET) %s\n" "$(1)"
endef

define ok
	@printf "$(GREEN)✅$(RESET) %s\n" "$(1)"
endef

define warn
	@printf "$(YELL)⚠️$(RESET)  %s\n" "$(1)"
endef

# Common xcodebuild flags
XCODEBUILD := xcodebuild \
	-project "$(PROJECT)" \
	-scheme "$(SCHEME)" \
	-destination 'platform=macOS' \
	-derivedDataPath "$(DERIVED_DATA)"

# Paths to built products

DEBUG_APP   := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION_DEBUG)/$(APP_NAME).app
RELEASE_APP := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION_RELEASE)/$(APP_NAME).app
DIST_APP    := $(DIST_DIR)/$(APP_NAME).app
DIST_PKG    := $(DIST_DIR)/TokenMon-$(VERSION).pkg
DIST_ZIP    := $(DIST_DIR)/TokenMon-$(VERSION).zip
DIST_DSYM   := $(DIST_DIR)/TokenMon-$(VERSION)-dSYM.zip
RELEASE_DSYM := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION_RELEASE)/$(APP_NAME).app.dSYM
PKG_COMPONENT_PLIST := $(BUILD_DIR)/TokenMon-component.plist

# Help

help tasks: ## Show this help message
	@printf "\n$(BOLD)TokenMon$(RESET) — macOS menu bar usage monitor\n"
	@printf "Version: $(VERSION)\n\n"
	@printf "Available commands:\n"
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'
	@printf "\nSigning:\n"
	@if [ -n "$(DEVELOPER_ID_APP)" ]; then \
		printf "  App:       $(GREEN)%s$(RESET)\n" "$(DEVELOPER_ID_APP)"; \
	else \
		printf "  App:       $(YELL)ad-hoc (no Developer ID Application found)$(RESET)\n"; \
	fi
	@if [ -n "$(DEVELOPER_ID_INSTALLER)" ]; then \
		printf "  Installer: $(GREEN)%s$(RESET)\n" "$(DEVELOPER_ID_INSTALLER)"; \
	else \
		printf "  Installer: $(YELL)unsigned pkg (no Developer ID Installer found)$(RESET)\n"; \
	fi
	@printf "\nExamples:\n"
	@printf "  make test          # Run unit tests\n"
	@printf "  make lint          # SwiftLint strict gate (must be clean)\n"
	@printf "  make build          # Debug .app\n"
	@printf "  make run            # Build Debug and launch\n"
	@printf "  make install        # Release → /Applications\n"
	@printf "  make release        # dist/: .app + .pkg + .zip + dSYM zip\n"
	@printf "  make release NOTARY=1   # also notarize (needs notarytool profile)\n"
	@printf "\n"

# Build

build: ## Build Debug configuration (ad-hoc signed)
	$(call say,Building $(APP_NAME) [$(CONFIGURATION_DEBUG)]…)
	@$(XCODEBUILD) \
		-configuration $(CONFIGURATION_DEBUG) \
		CODE_SIGN_IDENTITY="-" \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGNING_ALLOWED=YES \
		build
	$(call ok,Debug build ready)
	@printf "   $(DEBUG_APP)\n"

# Run

run: build ## Build Debug and launch the app
	$(call say,Launching $(APP_NAME)…)
	@# Menu bar agent — kill any previous instance and wait for it to exit.
	@# Reopening before the old process finishes makes LaunchServices return
	@# -600 (procNotFound), so bound the wait and retry once after re-registering.
	@pkill -x "$(APP_NAME)" 2>/dev/null || true; \
	i=0; while pgrep -x "$(APP_NAME)" >/dev/null 2>&1 && [ $$i -lt 25 ]; do sleep 0.2; i=$$((i + 1)); done
	@open "$(DEBUG_APP)" 2>/dev/null || { \
		printf "$(YELL)⚠️  open failed; re-registering $(APP_NAME) and retrying…$(RESET)\n"; \
		/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$(DEBUG_APP)" >/dev/null 2>&1 || true; \
		sleep 1; \
		open "$(DEBUG_APP)"; \
	}
	$(call ok,Launched (menu bar — no Dock icon))

# Install / Uninstall

install: ## Build Release and install to /Applications
	$(call say,Building Release for install…)
	@$(MAKE) --no-print-directory _release-app
	$(call say,Installing to $(INSTALL_DIR)/$(APP_NAME).app…)
	@pkill -x "$(APP_NAME)" 2>/dev/null || true
	@rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	@ditto "$(RELEASE_APP)" "$(INSTALL_DIR)/$(APP_NAME).app"
	$(call ok,Installed → $(INSTALL_DIR)/$(APP_NAME).app)
	@printf "   Open with: open \"$(INSTALL_DIR)/$(APP_NAME).app\"\n"

uninstall: ## Remove app from /Applications
	$(call say,Removing $(INSTALL_DIR)/$(APP_NAME).app…)
	@pkill -x "$(APP_NAME)" 2>/dev/null || true
	@rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	$(call ok,Uninstalled)

# Release (.app + .pkg + .zip)

release: ## Full release: Release .app, .pkg, .zip, and dSYM zip into dist/
	@printf "\n$(BOLD)🚀 Release $(APP_NAME) v$(VERSION) ($(BUILD_NUMBER))$(RESET)\n\n"
	@$(MAKE) --no-print-directory _release-app
	@$(MAKE) --no-print-directory _stage-dist
	@$(MAKE) --no-print-directory pkg
	@$(MAKE) --no-print-directory _zip
	@$(MAKE) --no-print-directory _dsym
	@if [ "$(NOTARY)" = "1" ]; then \
		$(MAKE) --no-print-directory notarize; \
	fi
	@printf "\n$(GREEN)✅ Release complete$(RESET)\n"
	@printf "   App:  $(DIST_APP)\n"
	@printf "   Pkg:  $(DIST_PKG)\n"
	@printf "   Zip:  $(DIST_ZIP)\n"
	@printf "   dSYM: $(DIST_DSYM)\n"
	@shasum -a 256 "$(DIST_APP)/Contents/MacOS/$(APP_NAME)" "$(DIST_PKG)" "$(DIST_ZIP)" "$(DIST_DSYM)" 2>/dev/null | sed 's|^|   SHA: |' || true
	@printf "\n"

# Internal: Release xcodebuild (Developer ID when available)
_release-app:
	$(call say,Building $(APP_NAME) [$(CONFIGURATION_RELEASE)]…)
	@if [ -n "$(DEVELOPER_ID_APP)" ]; then \
		printf "   Signing with: $(DEVELOPER_ID_APP)\n"; \
		$(XCODEBUILD) \
			-configuration $(CONFIGURATION_RELEASE) \
			CODE_SIGN_IDENTITY="$(DEVELOPER_ID_APP)" \
			CODE_SIGN_STYLE=Manual \
			$(if $(DEVELOPMENT_TEAM),DEVELOPMENT_TEAM=$(DEVELOPMENT_TEAM),) \
			OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" \
			$(BUILD_NUMBER_FLAG) \
			build; \
	else \
		printf "   $(YELL)No Developer ID — ad-hoc signing$(RESET)\n"; \
		$(XCODEBUILD) \
			-configuration $(CONFIGURATION_RELEASE) \
			CODE_SIGN_IDENTITY="-" \
			$(BUILD_NUMBER_FLAG) \
			build; \
	fi
	@test -d "$(RELEASE_APP)" || { printf "$(RED)🚨 Build product missing: $(RELEASE_APP)$(RESET)\n"; exit 1; }
	$(call ok,Release .app built)

_stage-dist:
	$(call say,Staging dist/…)
	@rm -rf "$(DIST_DIR)"
	@mkdir -p "$(DIST_DIR)"
	@ditto "$(RELEASE_APP)" "$(DIST_APP)"
	@test -f "$(DIST_APP)/Contents/Resources/PrivacyInfo.xcprivacy" || { printf "$(RED)🚨 PrivacyInfo.xcprivacy missing from $(DIST_APP)$(RESET)\n"; exit 1; }
	$(call ok,Staged $(DIST_APP))

pkg: ## Build installer .pkg from dist/ (or Release product)
	@if [ ! -d "$(DIST_APP)" ]; then \
		$(MAKE) --no-print-directory _release-app; \
		$(MAKE) --no-print-directory _stage-dist; \
	fi
	$(call say,Creating installer package…)
	@rm -rf "$(BUILD_DIR)/pkgroot"
	@mkdir -p "$(BUILD_DIR)/pkgroot/Applications"
	@ditto "$(DIST_APP)" "$(BUILD_DIR)/pkgroot/Applications/$(APP_NAME).app"
	@# Non-relocatable: the installer always writes /Applications/TokenMon.app,
	@# even when a copy exists elsewhere (DerivedData, Downloads).
	@pkgbuild --analyze --root "$(BUILD_DIR)/pkgroot" "$(PKG_COMPONENT_PLIST)" >/dev/null
	@plutil -replace 0.BundleIsRelocatable -bool NO "$(PKG_COMPONENT_PLIST)"
	@test "$$(plutil -extract 0.BundleIsRelocatable raw -o - "$(PKG_COMPONENT_PLIST)")" = "false"
	@if [ -n "$(DEVELOPER_ID_INSTALLER)" ]; then \
		pkgbuild \
			--root "$(BUILD_DIR)/pkgroot" \
			--component-plist "$(PKG_COMPONENT_PLIST)" \
			--identifier "$(BUNDLE_ID)" \
			--version "$(VERSION)" \
			--install-location "/" \
			--sign "$(DEVELOPER_ID_INSTALLER)" \
			"$(DIST_PKG)"; \
	else \
		pkgbuild \
			--root "$(BUILD_DIR)/pkgroot" \
			--component-plist "$(PKG_COMPONENT_PLIST)" \
			--identifier "$(BUNDLE_ID)" \
			--version "$(VERSION)" \
			--install-location "/" \
			"$(DIST_PKG)"; \
		printf "$(YELL)⚠️  Package is unsigned (no Developer ID Installer)$(RESET)\n"; \
	fi
	@rm -rf "$(BUILD_DIR)/pkgroot"
	$(call ok,Package → $(DIST_PKG))

_zip:
	$(call say,Zipping app…)
	@rm -f "$(DIST_ZIP)"
	@ditto -c -k --keepParent "$(DIST_APP)" "$(DIST_ZIP)"
	$(call ok,Zip → $(DIST_ZIP))

_dsym:
	$(call say,Zipping dSYM…)
	@test -d "$(RELEASE_DSYM)" || { printf "$(RED)🚨 dSYM missing: $(RELEASE_DSYM)$(RESET)\n"; exit 1; }
	@rm -f "$(DIST_DSYM)"
	@ditto -c -k --keepParent "$(RELEASE_DSYM)" "$(DIST_DSYM)"
	$(call ok,dSYM → $(DIST_DSYM))

# Archive / Notarize (optional distribution path)

archive: ## Create an .xcarchive (Xcode Organizer-compatible)
	$(call say,Archiving…)
	@mkdir -p "$(BUILD_DIR)"
	@if [ -n "$(DEVELOPER_ID_APP)" ]; then \
		xcodebuild \
			-project "$(PROJECT)" \
			-scheme "$(SCHEME)" \
			-configuration $(CONFIGURATION_RELEASE) \
			-archivePath "$(ARCHIVE_PATH)" \
			CODE_SIGN_IDENTITY="$(DEVELOPER_ID_APP)" \
			CODE_SIGN_STYLE=Manual \
			$(if $(DEVELOPMENT_TEAM),DEVELOPMENT_TEAM=$(DEVELOPMENT_TEAM),) \
			OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" \
			$(BUILD_NUMBER_FLAG) \
			archive; \
	else \
		xcodebuild \
			-project "$(PROJECT)" \
			-scheme "$(SCHEME)" \
			-configuration $(CONFIGURATION_RELEASE) \
			-archivePath "$(ARCHIVE_PATH)" \
			CODE_SIGN_IDENTITY="-" \
			$(BUILD_NUMBER_FLAG) \
			archive; \
	fi
	$(call ok,Archive → $(ARCHIVE_PATH))

export: ## Export a Developer ID .app from the archive into build/export
	$(call say,Exporting from $(ARCHIVE_PATH)…)
	@if [ ! -d "$(ARCHIVE_PATH)" ]; then \
		printf "$(YELL)No archive found — running 'make archive' first$(RESET)\n"; \
		$(MAKE) --no-print-directory archive; \
	fi
	@rm -rf "$(EXPORT_DIR)"
	@xcodebuild -exportArchive \
		-archivePath "$(ARCHIVE_PATH)" \
		-exportPath "$(EXPORT_DIR)" \
		-exportOptionsPlist Scripts/ExportOptions.plist
	$(call ok,Exported → $(EXPORT_DIR))

notarize: ## Notarize + staple the dist app, then rebuild, notarize + staple the zip and pkg
	@if [ ! -d "$(DIST_APP)" ]; then \
		printf "$(RED)🚨 No dist app. Run: make release$(RESET)\n"; exit 1; \
	fi
	@if [ -z "$(DEVELOPER_ID_APP)" ]; then \
		printf "$(RED)🚨 Notarization needs a Developer ID Application identity; this build is ad-hoc signed.$(RESET)\n"; exit 1; \
	fi
	$(call say,Notarizing app via profile '$(NOTARY_PROFILE)'…)
	@./Scripts/notarize.sh "$(DIST_APP)" "$(NOTARY_PROFILE)"
	@# Rebuild the zip and pkg from the stapled app so both carry the ticket.
	@$(MAKE) --no-print-directory _zip
	@$(MAKE) --no-print-directory pkg
	@if [ -n "$(DEVELOPER_ID_INSTALLER)" ]; then \
		printf "$(CYAN)→$(RESET) Notarizing pkg…\n"; \
		./Scripts/notarize.sh "$(DIST_PKG)" "$(NOTARY_PROFILE)"; \
	else \
		printf "$(YELL)⚠️  Pkg not notarized: it needs a Developer ID Installer signature$(RESET)\n"; \
	fi
	$(call ok,Notarized + stapled)

# Test

test: ## Run full Xcode unit test suite (with code coverage)
	$(call say,Running Xcode tests…)
	@$(XCODEBUILD) \
		-configuration $(CONFIGURATION_DEBUG) \
		CODE_SIGN_IDENTITY="-" \
		-enableCodeCoverage YES \
		test
	$(call ok,Tests passed)

test-core: ## Run CLT-only core parser tests (no app host)
	$(call say,Running core tests…)
	@./Scripts/run_core_tests.sh
	$(call ok,Core tests passed)

# Lint gate

lint: ## SwiftLint strict gate — every warning is an error, required for a PR
	$(call say,Running SwiftLint (strict)…)
	@command -v swiftlint >/dev/null || { printf "$(RED)🚨 swiftlint not installed. brew install swiftlint$(RESET)\n"; exit 1; }
	@swiftlint lint --strict --reporter github-actions-logging
	$(call ok,Lint clean)

lint-fix: ## Auto-correct autocorrectable SwiftLint violations
	$(call say,Running SwiftLint --fix…)
	@swiftlint lint --fix
	@swiftlint lint --strict --reporter github-actions-logging
	$(call ok,Lint clean after fix)

format: ## SwiftFormat lint gate — detect formatting drift
	$(call say,Running SwiftFormat (lint)…)
	@command -v swiftformat >/dev/null || { printf "$(RED)🚨 swiftformat not installed. brew install swiftformat$(RESET)\n"; exit 1; }
	@swiftformat . --lint
	$(call ok,Format clean)

format-fix: ## Auto-format all Swift sources
	$(call say,Running SwiftFormat…)
	@swiftformat .
	$(call ok,Formatted)

secrets: ## Secret scan gate — working tree and full git history
	$(call say,Running gitleaks (secret scan)…)
	@command -v gitleaks >/dev/null || { printf "$(RED)🚨 gitleaks not installed. brew install gitleaks$(RESET)\n"; exit 1; }
	@gitleaks dir . --no-banner
	@gitleaks detect --no-banner --log-opts="--all"
	$(call ok,No secrets found)

# Project maintenance

project: ## Regenerate Xcode project with xcodegen
	$(call say,Running xcodegen…)
	@command -v xcodegen >/dev/null || { printf "$(RED)🚨 xcodegen not installed. brew install xcodegen$(RESET)\n"; exit 1; }
	@xcodegen generate
	$(call ok,TokenMon.xcodeproj regenerated)

icon: ## Regenerate AppIcon asset catalog
	$(call say,Generating app icon…)
	@swift Scripts/generate_icon.swift TokenMon/Resources/Assets.xcassets/AppIcon.appiconset
	$(call ok,Icon set updated)

check: ## Verify Xcode CLI is pointed at Xcode.app
	$(call say,Checking toolchain…)
	@xcode-select -p
	@xcodebuild -version
	@swift --version | head -1
	@if [ -n "$(DEVELOPER_ID_APP)" ]; then printf "   App identity: $(DEVELOPER_ID_APP)\n"; fi
	@if [ -n "$(DEVELOPER_ID_INSTALLER)" ]; then printf "   Installer identity: $(DEVELOPER_ID_INSTALLER)\n"; fi
	@if [ -n "$(DEVELOPMENT_TEAM)" ]; then printf "   Team ID: $(DEVELOPMENT_TEAM)\n"; fi
	$(call ok,Toolchain OK)

open: ## Open the project in Xcode
	@open "$(PROJECT)"

# Clean

clean: ## Remove build/ and local DerivedData
	$(call say,Cleaning build artifacts…)
	@rm -rf "$(BUILD_DIR)" .build
	$(call ok,Clean)

distclean: clean ## Remove build/ and dist/
	$(call say,Removing dist/…)
	@rm -rf "$(DIST_DIR)"
	$(call ok,Dist clean)

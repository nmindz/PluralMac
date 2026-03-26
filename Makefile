# PluralMac – local development Makefile
# Usage: make [build|install|uninstall|clean|run|open]

PROJECT      := PluralMac.xcodeproj
SCHEME       := PluralMac
CONFIGURATION := Release
DERIVED_DATA := $(CURDIR)/build
APP_NAME     := PluralMac.app
APP_BUNDLE   := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/$(APP_NAME)
INSTALL_DIR  := /Applications
SIGN_IDENTITY := Apple Development: nightmaremindz@gmail.com (UF98E359JX)

# Version from latest git tag (e.g. v1.2.0 → 1.2.0), fallback to 0.1.0
VERSION      := $(shell git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 0.1.0)
COMMIT_SHA   := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
BUILD_NUMBER := $(shell git rev-list --count HEAD 2>/dev/null || echo 1)

.PHONY: build install uninstall clean run open buildinfo

build: buildinfo
	xcodebuild clean build \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		-derivedDataPath $(DERIVED_DATA) \
		CODE_SIGN_IDENTITY="$(SIGN_IDENTITY)" \
		CODE_SIGN_STYLE=Manual \
		DEVELOPMENT_TEAM="" \
		PROVISIONING_PROFILE_SPECIFIER="" \
		MARKETING_VERSION="$(VERSION)-$(COMMIT_SHA)" \
		CURRENT_PROJECT_VERSION="$(BUILD_NUMBER)"

buildinfo:
	@echo '// Auto-generated — do not edit' > PluralMac/BuildInfo.swift
	@echo 'enum BuildInfo {' >> PluralMac/BuildInfo.swift
	@echo '    static let commitSHA = "$(COMMIT_SHA)"' >> PluralMac/BuildInfo.swift
	@echo '    static let version = "$(VERSION)"' >> PluralMac/BuildInfo.swift
	@echo '}' >> PluralMac/BuildInfo.swift

install: build
	@echo "Installing $(APP_NAME) to $(INSTALL_DIR)…"
	@rm -rf "$(INSTALL_DIR)/$(APP_NAME)"
	ditto "$(APP_BUNDLE)" "$(INSTALL_DIR)/$(APP_NAME)"
	@echo "Done."

uninstall:
	@echo "Removing $(APP_NAME) from $(INSTALL_DIR)…"
	rm -rf "$(INSTALL_DIR)/$(APP_NAME)"
	@echo "Cleaning PluralMac user data…"
	rm -rf ~/Library/PluralMac
	@echo "Done."

clean:
	xcodebuild clean \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		-derivedDataPath $(DERIVED_DATA)
	rm -rf $(DERIVED_DATA)

run: build
	open "$(APP_BUNDLE)"

open:
	open $(PROJECT)

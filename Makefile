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

.PHONY: build install uninstall clean run open

build:
	xcodebuild build \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		-derivedDataPath $(DERIVED_DATA) \
		CODE_SIGN_IDENTITY="$(SIGN_IDENTITY)" \
		CODE_SIGN_STYLE=Manual \
		DEVELOPMENT_TEAM="" \
		PROVISIONING_PROFILE_SPECIFIER=""

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

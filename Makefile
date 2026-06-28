# Makefile — VoiceInput menu-bar voice input app
#
# Targets:
#   make build    Compile the release binary with SwiftPM
#   make app      Assemble + ad-hoc sign the .app bundle (hardened runtime)
#   make run      Build the bundle and launch it
#   make install  Build and copy the bundle to /Applications
#   make clean    Remove build artifacts and the bundle

APP_NAME    := VoiceInput
BUNDLE_ID   := com.voiceinput.app
CONFIG      := release
BUILD_DIR   := .build/$(CONFIG)
APP_BUNDLE  := $(APP_NAME).app
CONTENTS    := $(APP_BUNDLE)/Contents
MACOS_DIR   := $(CONTENTS)/MacOS
RES_DIR     := $(CONTENTS)/Resources
ENTITLEMENTS := Resources/$(APP_NAME).entitlements

# Use the developer's signing identity if provided, otherwise ad-hoc ("-").
# Ad-hoc signing satisfies the "signed .app" requirement for personal use.
SIGN_IDENTITY ?= -

.PHONY: all build app sign run install clean

all: app

build:
	swift build -c $(CONFIG)

app: build
	@echo ">> Assembling $(APP_BUNDLE)"
	rm -rf "$(APP_BUNDLE)"
	mkdir -p "$(MACOS_DIR)" "$(RES_DIR)"
	cp "$(BUILD_DIR)/$(APP_NAME)" "$(MACOS_DIR)/$(APP_NAME)"
	cp Resources/Info.plist "$(CONTENTS)/Info.plist"
	cp Resources/AppIcon.icns "$(RES_DIR)/AppIcon.icns"
	printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	$(MAKE) sign
	@echo ">> Done: $(APP_BUNDLE)"

# Ad-hoc sign with hardened runtime + entitlements (audio input).
# No --deep: the bundle has a single statically-linked executable and no nested
# code, and Apple discourages --deep for signing (it applies entitlements only to
# the top-level binary). Sign the one executable directly.
sign:
	codesign --force --options runtime \
		--entitlements "$(ENTITLEMENTS)" \
		--sign "$(SIGN_IDENTITY)" "$(APP_BUNDLE)"
	@echo ">> Signature:"
	@codesign --display --verbose=2 "$(APP_BUNDLE)" 2>&1 | sed 's/^/   /'

run: app
	@echo ">> Launching $(APP_BUNDLE)"
	open "$(APP_BUNDLE)"

install: app
	@echo ">> Installing to /Applications/$(APP_BUNDLE)"
	rm -rf "/Applications/$(APP_BUNDLE)"
	cp -R "$(APP_BUNDLE)" /Applications/
	@echo ">> Installed. Launch it from /Applications and grant Microphone, Speech Recognition, and Accessibility permissions."

clean:
	-swift package clean
	rm -rf "$(APP_BUNDLE)" .build

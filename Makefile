# Makefile — VoiceInput menu-bar voice input app
#
# Targets:
#   make build    Compile the release binary with SwiftPM
#   make app      Assemble + sign the .app (auto-detects 'VoiceInput Local' cert, else ad-hoc)
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

# Signing identity. Defaults to the local self-signed "VoiceInput Local" cert when
# it's present — a STABLE identity means the macOS Accessibility/TCC grant survives
# rebuilds (ad-hoc changes the code hash every build and invalidates the grant).
# Falls back to ad-hoc ("-") when the cert isn't installed. Override for a real
# Developer ID with:  make SIGN_IDENTITY="Developer ID Application: …"
SIGN_IDENTITY ?= $(shell security find-identity -p codesigning 2>/dev/null | grep -q 'VoiceInput Local' && echo 'VoiceInput Local' || echo '-')

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

# Sign with hardened runtime + entitlements (audio input). Uses $(SIGN_IDENTITY):
# the local 'VoiceInput Local' cert if present (stable identity), else ad-hoc.
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

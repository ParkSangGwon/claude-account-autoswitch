# Claude AutoSwitch — macOS menu bar app with its own Claude proxy.
#
#   make build      swift build (release)
#   make test       swift test
#   make app        assemble dist/Claude AutoSwitch.app (ad-hoc signed)
#   make smoke      launch the bundle with a scratch config and check the listener answers
#   make run        make app, then open it
#   make install    copy the bundle to /Applications
#   make clean
#
# The bundle version comes from the VERSION file at the repository root.
#
# SCRATCH=<dir> builds in a private directory (swift --scratch-path) instead of
# .build, for a second checkout or agent that must not race this one's build.

SWIFT ?= swift
SCRATCH ?=
SCRATCH_FLAG := $(if $(SCRATCH),--scratch-path $(SCRATCH),)
PRODUCT := ClaudeAutoSwitch
APP_NAME := Claude AutoSwitch
DIST := dist
APP := $(DIST)/$(APP_NAME).app
VERSION := $(shell cat VERSION 2>/dev/null || echo 0.0.0)
BIN := $(shell $(SWIFT) build -c release $(SCRATCH_FLAG) --show-bin-path 2>/dev/null)

.PHONY: build test app smoke run install clean

build:
	$(SWIFT) build -c release $(SCRATCH_FLAG) --product $(PRODUCT)

test:
	$(SWIFT) test $(SCRATCH_FLAG)

app: build
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp "$(BIN)/$(PRODUCT)" "$(APP)/Contents/MacOS/$(PRODUCT)"
	cp -R "$(BIN)/$(PRODUCT)_AutoSwitchCore.bundle" "$(APP)/Contents/Resources/"
	sed 's/__VERSION__/$(VERSION)/g' Resources/Info.plist > "$(APP)/Contents/Info.plist"
	printf 'APPL????' > "$(APP)/Contents/PkgInfo"
	@if [ -d Resources/AppIcon.iconset ]; then iconutil -c icns Resources/AppIcon.iconset -o "$(APP)/Contents/Resources/AppIcon.icns"; fi
	codesign --force --deep --sign - --identifier com.parksanggwon.claudeautoswitch "$(APP)"
	@echo "built $(APP) ($(VERSION))"

smoke: app
	scripts/smoke.sh "$(APP)"

run: app
	open "$(APP)"

install: app
	rm -rf "/Applications/$(APP_NAME).app"
	cp -R "$(APP)" "/Applications/$(APP_NAME).app"
	@echo "installed /Applications/$(APP_NAME).app"

clean:
	rm -rf .build $(DIST)

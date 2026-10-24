VERSION ?= 1.0.0
BUILD_NUMBER ?= 1
INSTALL ?= 1
APP := dist/flashCat.app
INSTALLED_APP := /Applications/flashCat.app
SPLASH_SRC ?= ../tmp/splash-src
# splash engine version (vendor/splash-<version>-arm64-macos26.tar.gz).
# Separate from VERSION, which is the flashCat app version.
SPLASH_VERSION ?= 1.4.0

.PHONY: all app install pkg dmg verify run uninstall analyze test windows linux runtime runtime-check fetch-runtime clean

all: app

## Build the Flutter macOS app, make the installers, and install into /Applications.
app:
	VERSION=$(VERSION) BUILD_NUMBER=$(BUILD_NUMBER) INSTALL=$(INSTALL) SPLASH_VERSION=$(SPLASH_VERSION) ./scripts/build-app.sh

## (Re)install an already built bundle into /Applications.
install:
	VERSION=$(VERSION) ./scripts/install-app.sh

## dist/flashCat-<version>.pkg (double-click installs) and .dmg (drag to Applications).
pkg: dmg

dmg:
	VERSION=$(VERSION) BUILD_NUMBER=$(BUILD_NUMBER) ./scripts/make-installer.sh

## Launch the installed app and confirm the native process stays alive.
verify: install
	@open "$(INSTALLED_APP)"
	@sleep 4
	@pgrep -f "$(INSTALLED_APP)/Contents/MacOS/flashCat" >/dev/null || { \
		echo "error: installed app did not stay running" >&2; exit 1; }
	@echo "APP LAUNCH OK"

run:
	open "$(INSTALLED_APP)"

## Remove the installed app and any inference server it left holding the port.
uninstall:
	@for pid in $$(pgrep -f "$(INSTALLED_APP)/Contents/MacOS/flashCat" || true); do kill "$$pid"; done
	@for pid in $$(pgrep -f "$(INSTALLED_APP)/Contents/Resources/runtime" || true); do kill "$$pid"; done
	@if [ -e "$(INSTALLED_APP)" ]; then rm -rf "$(INSTALLED_APP)"; echo "removed $(INSTALLED_APP)"; else echo "nothing installed"; fi
	@rm -rf /Applications/.flashCat-previous-*.app
	@rm -f "$$HOME/Library/LaunchAgents/com.zhuo.flashcat.plist"

analyze:
	flutter analyze

test:
	flutter test

windows:
	flutter build windows --release

linux:
	flutter build linux --release

## Download the official splash runtime archive (latest, or SPLASH_VERSION) into vendor/.
fetch-runtime:
	./scripts/fetch-runtime.sh $(SPLASH_VERSION)

## Rebuild the splash runtime archive from a local source checkout.
runtime:
	@test -d "$(SPLASH_SRC)" || { echo "missing splash source: $(SPLASH_SRC)"; exit 1; }
	$(MAKE) -C "$(SPLASH_SRC)" package RELEASE_VERSION=$(SPLASH_VERSION)
	cp "$(SPLASH_SRC)/dist/splash-$(SPLASH_VERSION)-arm64-macos26.tar.gz" vendor/

## Confirm the vendored runtime archive matches SPLASH_VERSION.
runtime-check:
	@test -f "vendor/splash-$(SPLASH_VERSION)-arm64-macos26.tar.gz" || { \
		echo "error: vendor/splash-$(SPLASH_VERSION)-arm64-macos26.tar.gz missing"; exit 1; }
	@tar -xzf "vendor/splash-$(SPLASH_VERSION)-arm64-macos26.tar.gz" -O splash-$(SPLASH_VERSION)-arm64-macos26/release.json \
		| grep -o '"version": *"[^"]*"'

clean:
	flutter clean
	@echo "Removed Flutter build output. dist/ is kept."

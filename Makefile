VERSION ?= 1.1.0
BUILD_NUMBER ?= 4
INSTALL ?= 1
SPLASH_VERSION ?= 1.4.0

INSTALLED_APP := /Applications/flashCat.app

.PHONY: all app install pkg dmg verify run uninstall splash-pack pack-index clean

all: app

## Build the native SwiftUI macOS app, make the installers, and install into /Applications.
app:
	VERSION=$(VERSION) BUILD_NUMBER=$(BUILD_NUMBER) INSTALL=$(INSTALL) ./scripts/build-native-app.sh

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
	@if [ -e "$(INSTALLED_APP)" ]; then rm -rf "$(INSTALLED_APP)"; echo "removed $(INSTALLED_APP)"; else echo "nothing installed"; fi
	@rm -rf /Applications/.flashCat-previous-*.app
	@rm -f "$$HOME/Library/LaunchAgents/com.zhuo.flashCat.plist"

## Unpack the vendored splash release into an installable runtime pack.
splash-pack:
	./scripts/engines/build-splash-pack.sh --version $(SPLASH_VERSION)

## Rebuild pack-index.json from dist/packs/*.release.json.
pack-index:
	./scripts/engines/make-pack-index.sh

## Remove build output (the installed app and the installers are kept).
clean:
	rm -rf native/.build dist/.build dist/AppIcon.iconset
	@echo "Removed native build output."

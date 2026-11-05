ROOT := $(shell pwd)
# `VERSION` at the repo root is the single source of truth; scripts/version.sh
# validates its shape. Override on the command line only for a throwaway build.
VERSION ?= $(shell $(ROOT)/scripts/version.sh)
BUILD_NUMBER ?= $(shell $(ROOT)/scripts/version.sh --build)
INSTALL ?= 1
SPLASH_VERSION ?= 1.4.0

INSTALLED_APP := /Applications/flashCat.app

.PHONY: all app install pkg dmg verify run uninstall splash-pack pack-index clean test webui-check webui-build

all: app

## Bundle the WebUI ES modules into a single classic script (esbuild, ~100ms).
## file:// 下的 WebKit 拒绝外链 ES module（CORS），所以产物必须是经典脚本；
## bundle.js 是提交进仓库的构建产物，CI 校验它与源码同步。
webui-build:
	npm run --silent build:webui

## Build the native SwiftUI macOS app, make the installers, and install into /Applications.
app: webui-build
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
## Entries are the archives' own file names; pass BASE_URL when the archives
## live somewhere else than beside the index (`make pack-index BASE_URL=…`).
pack-index:
	./scripts/engines/make-pack-index.sh $(if $(BASE_URL),--base-url $(BASE_URL),)

## Swift unit tests (kit + app shell). Fast, no UI.
test:
	cd native && swift test

## Render every WebUI page in a real WKWebView and assert it paints.
## Catches a blank page, a missing script and a stale snapshot fixture.
webui-check: webui-build
	cd native && swift run webui-render-check --webui Sources/FlashCat/WebUI

## Remove build output (the installed app and the installers are kept).
clean:
	rm -rf native/.build dist/.build dist/AppIcon.iconset
	@echo "Removed native build output."

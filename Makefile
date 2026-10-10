DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR
# `<cacheRoot>/DevPlugins`, scanned by Debug hosts only (AppEnvironment+BootstrapStores,
# PluginTrust.scansDevPluginsDirectory); cacheRoot is AinkradHome.defaultCacheRoot.
DEV_PLUGINS := $(HOME)/Library/Application Support/com.ainkrad.app/Cache/DevPlugins
XCODEBUILD := xcodebuild -scheme GrimoirePlugin -derivedDataPath build -destination 'platform=macOS'

generate: ; xcodegen generate
build: lint generate ; $(XCODEBUILD) -configuration Debug build
test: lint generate ; $(XCODEBUILD) -configuration Debug test
releasebuild: generate ; $(XCODEBUILD) -configuration Release build
sideload: build
	mkdir -p "$(DEV_PLUGINS)"
	rm -rf "$(DEV_PLUGINS)/GrimoirePlugin.bundle"
	cp -R build/Build/Products/Debug/GrimoirePlugin.bundle "$(DEV_PLUGINS)/GrimoirePlugin.bundle"
# Releasing goes through scripts/release.sh, never `ainkrad publish` alone: it
# builds clean, Developer-ID signs, publishes the GitHub release and updates the
# catalog. SIGN_IDENTITY="Developer ID Application: ..." make release V=v0.1.0
release: ; ./scripts/release.sh $(V)

.PHONY: generate build test releasebuild sideload release

include scripts/guardrails.mk

.PHONY: build test install uninstall uninstall-all clean

APP_NAME := ClaudeUsageMonitor
PROJECT := $(APP_NAME).xcodeproj
BUNDLE_ID := $(shell sed -n 's/^[[:space:]]*PRODUCT_BUNDLE_IDENTIFIER = \(.*\);/\1/p' $(PROJECT)/project.pbxproj | head -1)
APP := build/Build/Products/Release/$(APP_NAME).app
DEST := /Applications/$(APP_NAME).app

build:
	xcodebuild -project $(PROJECT) -scheme $(APP_NAME) -configuration Release -derivedDataPath build build

test:
	swift test --package-path Core

install: build
	rm -rf "$(DEST)"
	cp -R "$(APP)" "$(DEST)"
	@echo "$(DEST) にインストールしました。"

uninstall:
	@if [ -e "$(DEST)" ]; then \
	    rm -rf "$(DEST)" && echo "$(DEST) を削除しました。"; \
	else \
	    echo "$(DEST) はインストールされていません。"; \
	fi

# 設定は cfprefsd が持っているため、plist を直接消さず defaults で消す。
# BUNDLE_ID が空だと各ディレクトリの親ごと消えるため、先に止める
uninstall-all:
	@if [ -z "$(BUNDLE_ID)" ]; then \
	    echo "bundle ID を $(PROJECT) から取得できませんでした。"; exit 1; \
	fi; \
	if pgrep -x "$(APP_NAME)" >/dev/null; then \
	    echo "$(APP_NAME) が動いています。終了してからやり直してください。"; exit 1; \
	fi; \
	lib="$(HOME)/Library"; \
	paths="$(DEST)|$$lib/Containers/$(BUNDLE_ID)|$$lib/Application Scripts/$(BUNDLE_ID)|$$lib/WebKit/$(BUNDLE_ID)|$$lib/Caches/$(BUNDLE_ID)|$$lib/HTTPStorages/$(BUNDLE_ID)|$$lib/HTTPStorages/$(BUNDLE_ID).binarycookies|$$lib/Saved Application State/$(BUNDLE_ID).savedState"; \
	targets=""; \
	IFS='|'; for path in $$paths; do \
	    if [ -e "$$path" ]; then targets="$$targets  $$path\n"; fi; \
	done; unset IFS; \
	has_defaults=0; \
	if defaults read "$(BUNDLE_ID)" >/dev/null 2>&1; then \
	    has_defaults=1; targets="$$targets  設定 (defaults のドメイン $(BUNDLE_ID))\n"; \
	fi; \
	if [ -z "$$targets" ]; then echo "削除するものはありません。"; exit 0; fi; \
	echo "次のものを削除します:"; printf "%b" "$$targets"; \
	printf "よろしいですか？ [y/N] "; read -r answer; \
	if [ "$$answer" != y ]; then echo "中止しました。"; exit 0; fi; \
	IFS='|'; for path in $$paths; do rm -rf "$$path"; done; unset IFS; \
	if [ $$has_defaults -eq 1 ]; then defaults delete "$(BUNDLE_ID)"; fi; \
	echo "削除しました。"

clean:
	rm -rf build Core/.build

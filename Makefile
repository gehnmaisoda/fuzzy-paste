APP_NAME = FuzzyPaste
CLI_NAME = fpaste
BUNDLE_ID = com.gehnmaisoda.FuzzyPaste
BUILD_DIR = .build/release
APP_BUNDLE = $(APP_NAME).app
DMG_NAME = $(APP_NAME).dmg
DEV_FLAGS = -Xswiftc -DDEV

.PHONY: run test relaunch relaunch_release hard_reset clean seed dist

define make_bundle
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	mkdir -p $(APP_BUNDLE)/Contents/Resources
	cp $(BUILD_DIR)/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/
	cp $(BUILD_DIR)/$(CLI_NAME) $(APP_BUNDLE)/Contents/MacOS/
	cp Resources/Info.plist $(APP_BUNDLE)/Contents/
	cp Resources/AppIcon.icns $(APP_BUNDLE)/Contents/Resources/
	-pkill -x $(APP_NAME)
	open $(APP_BUNDLE)
endef

define make_bundle_only
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	mkdir -p $(APP_BUNDLE)/Contents/Resources
	cp $(BUILD_DIR)/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/
	cp $(BUILD_DIR)/$(CLI_NAME) $(APP_BUNDLE)/Contents/MacOS/
	cp Resources/Info.plist $(APP_BUNDLE)/Contents/
	cp Resources/AppIcon.icns $(APP_BUNDLE)/Contents/Resources/
endef

run:
	swift build $(DEV_FLAGS)
	.build/debug/$(APP_NAME)

test:
	swift test

relaunch:
	swift build -c release $(DEV_FLAGS)
	$(make_bundle)

relaunch_release:
	swift build -c release
	$(make_bundle)

hard_reset:
	-pkill -x $(APP_NAME)
	tccutil reset Accessibility $(BUNDLE_ID)
	rm -rf ~/Library/Application\ Support/FuzzyPaste-Dev
	@echo "Hard reset complete"

seed:
	swift build $(DEV_FLAGS)
	./scripts/seed.sh

dist:
	swift build -c release
	$(make_bundle_only)
	codesign --force --deep -s - $(APP_BUNDLE)
	rm -f $(DMG_NAME)
	create-dmg \
		--volname "$(APP_NAME)" \
		--background Resources/dmg-background.png \
		--window-pos 200 120 \
		--window-size 600 400 \
		--icon-size 100 \
		--icon "$(APP_BUNDLE)" 160 165 \
		--app-drop-link 440 165 \
		--hide-extension "$(APP_BUNDLE)" \
		--no-internet-enable \
		$(DMG_NAME) \
		$(APP_BUNDLE)
	rm -rf $(APP_BUNDLE)
	@echo "Created $(DMG_NAME)"

clean:
	swift package clean
	rm -rf $(APP_BUNDLE) $(DMG_NAME)

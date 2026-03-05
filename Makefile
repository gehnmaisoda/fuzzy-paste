APP_NAME = FuzzyPaste
CLI_NAME = fpaste
BUNDLE_ID = com.gehnmaisoda.FuzzyPaste
BUILD_DIR = .build/release
APP_BUNDLE = $(APP_NAME).app
DEV_FLAGS = -Xswiftc -DDEV

.PHONY: run relaunch relaunch_release hard_reset clean seed

define make_bundle
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	mkdir -p $(APP_BUNDLE)/Contents/Resources
	cp $(BUILD_DIR)/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/
	cp $(BUILD_DIR)/$(CLI_NAME) $(APP_BUNDLE)/Contents/MacOS/
	cp Resources/Info.plist $(APP_BUNDLE)/Contents/
	-pkill -x $(APP_NAME)
	open $(APP_BUNDLE)
endef

run:
	swift build $(DEV_FLAGS)
	.build/debug/$(APP_NAME)

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

clean:
	swift package clean
	rm -rf $(APP_BUNDLE)

APP_NAME = FuzzyPaste
CLI_NAME = fpaste
BUNDLE_ID = com.gehnmaisoda.FuzzyPaste
BUILD_DIR = .build/release
APP_BUNDLE = $(APP_NAME).app

.PHONY: build run clean bundle relaunch hard_reset install

build:
	swift build

release:
	swift build -c release

run: build
	.build/debug/$(APP_NAME)

bundle: release
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	mkdir -p $(APP_BUNDLE)/Contents/Resources
	cp $(BUILD_DIR)/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/
	cp $(BUILD_DIR)/$(CLI_NAME) $(APP_BUNDLE)/Contents/MacOS/
	cp Resources/Info.plist $(APP_BUNDLE)/Contents/
	@echo "Created $(APP_BUNDLE)"

install: release
	ln -sf $(abspath $(BUILD_DIR)/$(CLI_NAME)) /usr/local/bin/$(CLI_NAME)
	@echo "Installed $(CLI_NAME) -> /usr/local/bin/$(CLI_NAME)"

relaunch: bundle
	-pkill -x $(APP_NAME)
	open $(APP_BUNDLE)

hard_reset:
	-pkill -x $(APP_NAME)
	tccutil reset Accessibility $(BUNDLE_ID)
	rm -rf ~/Library/Application\ Support/FuzzyPaste
	@echo "Hard reset complete"

clean:
	swift package clean
	rm -rf $(APP_BUNDLE)

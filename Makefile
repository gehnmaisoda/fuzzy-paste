APP_NAME = FuzzyPaste
BUILD_DIR = .build/release
APP_BUNDLE = $(APP_NAME).app

.PHONY: build run clean bundle

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
	cp Resources/Info.plist $(APP_BUNDLE)/Contents/
	@echo "Created $(APP_BUNDLE)"

clean:
	swift package clean
	rm -rf $(APP_BUNDLE)

# Generate the example Xcode project and run the SDK tests on a simulator.
# Requires full Xcode (not just the Command Line Tools, and `xcode-select` pointed at
# it) and XcodeGen (`brew install xcodegen`).

# Auto-pick the first available iPhone simulator (robust across Xcode versions: iPhone 16
# on CI's macos image, iPhone 17 on a newer local Xcode). Override with DESTINATION=...
SIM_ID = $(shell xcrun simctl list devices available | grep 'iPhone' | head -1 | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}')
DESTINATION ?= platform=iOS Simulator,id=$(SIM_ID)

.PHONY: generate test-ui unit clean

generate:
	xcodegen generate

# End-to-end UI tests, driven through the example app.
test-ui: generate
	xcodebuild test \
	  -project CatchDevExample.xcodeproj \
	  -scheme CatchDevExample \
	  -destination '$(DESTINATION)' \
	  CODE_SIGNING_ALLOWED=NO

# Library unit tests (run from the package root).
unit:
	cd .. && swift test

clean:
	rm -rf CatchDevExample.xcodeproj build CatchDevExample/Info.plist

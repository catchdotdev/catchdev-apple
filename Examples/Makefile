# Generate the example Xcode project and run the SDK tests on a simulator.
# Requires full Xcode (not just the Command Line Tools) and XcodeGen
# (`brew install xcodegen`).

DESTINATION ?= platform=iOS Simulator,name=iPhone 16

.PHONY: generate test-ui unit clean

generate:
	xcodegen generate

# End-to-end UI tests, driven through the example app.
test-ui: generate
	xcodebuild test \
	  -project CatchDevExample.xcodeproj \
	  -scheme CatchDevExample \
	  -destination '$(DESTINATION)'

# Library unit tests (run from the package root).
unit:
	cd .. && swift test

clean:
	rm -rf CatchDevExample.xcodeproj build CatchDevExample/Info.plist

# Generate the example Xcode project and run the SDK tests on a simulator.
# Requires full Xcode (not just the Command Line Tools, and `xcode-select` pointed at
# it) and XcodeGen (`brew install xcodegen`).

# Pick a simulator. By default scripts/pick-simulator.sh auto-picks the first available
# iPhone (latest installed runtime). Set IOS_VERSION (e.g. `make test-ui IOS_VERSION=16.4`)
# to run against a specific iOS runtime — the script installs that runtime and creates a
# matching iPhone if needed. Override the whole thing with DESTINATION=...
DESTINATION ?= $(shell scripts/pick-simulator.sh $(IOS_VERSION))

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

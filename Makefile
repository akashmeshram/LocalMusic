.PHONY: build release dist install icon run test clean xcodeproj
build:
	@Scripts/build.sh debug
dist:
	@Scripts/dist.sh
release:
	@Scripts/build.sh release
run: build
	@open build/debug/LocalMusic.app
test:
	@Scripts/test.sh
install: dist
	@rm -rf /Applications/LocalMusic.app && ditto build/dist/LocalMusic.app /Applications/LocalMusic.app && touch /Applications/LocalMusic.app && echo "Installed /Applications/LocalMusic.app"
icon:
	@mkdir -p build && swiftc -sdk "$$(Scripts/sdk.sh)" -O -o build/make-icon Scripts/make-icon.swift && build/make-icon Sources/LocalMusic/Resources/AppIcon.icns && rm -f Sources/LocalMusic/Resources/AppIcon-preview.png
xcodeproj:
	@command -v xcodegen >/dev/null || { echo "brew install xcodegen"; exit 1; }
	@xcodegen generate
clean:
	@rm -rf build .build

.PHONY: build release run test clean xcodeproj
build:
	@Scripts/build.sh debug
release:
	@Scripts/build.sh release
run: build
	@open build/debug/LocalMusic.app
test:
	@Scripts/test.sh
xcodeproj:
	@command -v xcodegen >/dev/null || { echo "brew install xcodegen"; exit 1; }
	@xcodegen generate
clean:
	@rm -rf build .build

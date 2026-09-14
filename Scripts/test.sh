#!/bin/bash
# Compiles and runs the Swift Testing suite without SwiftPM.
set -euo pipefail
cd "$(dirname "$0")/.."
ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macosx14.0"
SDK="$(Scripts/sdk.sh)"
OUT="build/test"
mkdir -p "$OUT"
DEV_DIR="$(xcode-select -p 2>/dev/null || echo /Library/Developer/CommandLineTools)"
TESTING_FW=""
for d in "$DEV_DIR/Library/Developer/Frameworks" "$DEV_DIR/Platforms/MacOSX.platform/Developer/Library/Frameworks" /Library/Developer/CommandLineTools/Library/Developer/Frameworks; do
  [ -d "$d/Testing.framework" ] && TESTING_FW="$d" && break
done
[ -n "$TESTING_FW" ] || { echo "Testing.framework not found" >&2; exit 1; }
COMMON=(-sdk "$SDK" -target "$TARGET" -swift-version 6 -parse-as-library -Onone -g)

echo "▸ Building LocalMusicCore (testable)"
CORE_SOURCES=()
while IFS= read -r -d '' f; do CORE_SOURCES+=("$f"); done < <(find Sources/LocalMusicCore -name '*.swift' -print0 | sort -z)
swiftc "${COMMON[@]}" -enable-testing -module-name LocalMusicCore \
  -emit-module -emit-module-path "$OUT/LocalMusicCore.swiftmodule" \
  -emit-library -static -o "$OUT/libLocalMusicCore.a" "${CORE_SOURCES[@]}"

echo "▸ Building tests"
TEST_SOURCES=()
while IFS= read -r -d '' f; do TEST_SOURCES+=("$f"); done < <(find Tests/LocalMusicTests -name '*.swift' -print0 | sort -z)
cat > "$OUT/TestMain.swift" <<'MAIN'
@_spi(ForToolsIntegrationOnly) import Testing
@main struct TestRunner { static func main() async { await Testing.__swiftPMEntryPoint() as Never } }
MAIN
swiftc "${COMMON[@]}" -module-name LocalMusicTests \
  -I "$OUT" -L "$OUT" -lLocalMusicCore \
  -F "$TESTING_FW" -Xlinker -rpath -Xlinker "$TESTING_FW" -Xfrontend -disable-cross-import-overlays \
  -o "$OUT/LocalMusicTests" "${TEST_SOURCES[@]}" "$OUT/TestMain.swift"

echo "▸ Running tests"
"$OUT/LocalMusicTests" "$@"

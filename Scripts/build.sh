#!/bin/bash
# Builds LocalMusic.app with swiftc directly (no SwiftPM / Xcode required).
# Usage: Scripts/build.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-debug}"
ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macosx14.0"
SDK="$(Scripts/sdk.sh)"
OUT="build/$CONFIG"
APP="$OUT/LocalMusic.app"
mkdir -p "$OUT/core"

if [ "$CONFIG" = "release" ]; then OPT=(-O -whole-module-optimization); else OPT=(-Onone -g); fi
COMMON=(-sdk "$SDK" -target "$TARGET" -swift-version 6 -parse-as-library "${OPT[@]}")

echo "▸ SDK: $SDK"
echo "▸ Building LocalMusicCore"
CORE_SOURCES=()
while IFS= read -r -d '' f; do CORE_SOURCES+=("$f"); done < <(find Sources/LocalMusicCore -name '*.swift' -print0 | sort -z)
swiftc "${COMMON[@]}" -module-name LocalMusicCore \
  -emit-module -emit-module-path "$OUT/core/LocalMusicCore.swiftmodule" \
  -emit-library -static -o "$OUT/core/libLocalMusicCore.a" \
  "${CORE_SOURCES[@]}"

echo "▸ Building LocalMusic"
APP_SOURCES=()
while IFS= read -r -d '' f; do APP_SOURCES+=("$f"); done < <(find Sources/LocalMusic -name '*.swift' -print0 | sort -z)
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc "${COMMON[@]}" -module-name LocalMusic \
  -I "$OUT/core" -L "$OUT/core" -lLocalMusicCore \
  -o "$APP/Contents/MacOS/LocalMusic" \
  "${APP_SOURCES[@]}"

cp Sources/LocalMusic/Resources/Info.plist "$APP/Contents/Info.plist"
echo -n "APPL????" > "$APP/Contents/PkgInfo"
if [ -f Sources/LocalMusic/Resources/AppIcon.icns ]; then cp Sources/LocalMusic/Resources/AppIcon.icns "$APP/Contents/Resources/"; fi
codesign --force --sign - --entitlements Sources/LocalMusic/Resources/LocalMusic.entitlements "$APP" >/dev/null 2>&1 || codesign --force --sign - "$APP"
echo "▸ Built $APP"

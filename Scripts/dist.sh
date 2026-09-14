#!/bin/bash
# Builds a universal (arm64 + x86_64) optimized LocalMusic.app, signs it, optionally notarizes it,
# and zips it for distribution.
#
#   Scripts/dist.sh                      # ad-hoc signed (recipients must right-click → Open once)
#   CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" Scripts/dist.sh
#   CODESIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=localmusic Scripts/dist.sh
#
# NOTARY_PROFILE is a keychain profile created once with:
#   xcrun notarytool store-credentials localmusic --apple-id you@example.com --team-id TEAMID
set -euo pipefail
cd "$(dirname "$0")/.."
SDK="$(Scripts/sdk.sh)"
OUT="build/dist"
APP="$OUT/LocalMusic.app"
IDENTITY="${CODESIGN_IDENTITY:--}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Sources/LocalMusic/Resources/Info.plist)"
rm -rf "$OUT"; mkdir -p "$OUT"

CORE_SOURCES=(); while IFS= read -r -d '' f; do CORE_SOURCES+=("$f"); done < <(find Sources/LocalMusicCore -name '*.swift' -print0 | sort -z)
APP_SOURCES=();  while IFS= read -r -d '' f; do APP_SOURCES+=("$f");  done < <(find Sources/LocalMusic     -name '*.swift' -print0 | sort -z)

for ARCH in arm64 x86_64; do
  echo "▸ Building $ARCH"
  D="$OUT/$ARCH"; mkdir -p "$D"
  COMMON=(-sdk "$SDK" -target "$ARCH-apple-macosx14.0" -swift-version 6 -parse-as-library -O -whole-module-optimization)
  swiftc "${COMMON[@]}" -module-name LocalMusicCore -emit-module -emit-module-path "$D/LocalMusicCore.swiftmodule" \
    -emit-library -static -o "$D/libLocalMusicCore.a" "${CORE_SOURCES[@]}"
  swiftc "${COMMON[@]}" -module-name LocalMusic -I "$D" -L "$D" -lLocalMusicCore -o "$D/LocalMusic" "${APP_SOURCES[@]}"
done

echo "▸ Assembling universal bundle"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "$OUT/arm64/LocalMusic" "$OUT/x86_64/LocalMusic" -output "$APP/Contents/MacOS/LocalMusic"
cp Sources/LocalMusic/Resources/Info.plist "$APP/Contents/Info.plist"
echo -n "APPL????" > "$APP/Contents/PkgInfo"
[ -f Sources/LocalMusic/Resources/AppIcon.icns ] && cp Sources/LocalMusic/Resources/AppIcon.icns "$APP/Contents/Resources/"
cp README.md "$APP/Contents/Resources/README.md"

echo "▸ Signing with: $IDENTITY"
if [ "$IDENTITY" = "-" ]; then
  codesign --force --sign - "$APP"
else
  codesign --force --timestamp --options runtime --sign "$IDENTITY" \
    --entitlements Sources/LocalMusic/Resources/LocalMusic.entitlements "$APP"
fi
codesign --verify --deep --strict "$APP"

ZIP="$OUT/LocalMusic-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

if [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "▸ Notarizing"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"
fi

lipo -info "$APP/Contents/MacOS/LocalMusic"
du -sh "$APP" "$ZIP"
echo "▸ Done: $ZIP"

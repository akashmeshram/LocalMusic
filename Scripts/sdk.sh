#!/bin/bash
# Prints the path of a macOS SDK that the installed swiftc can actually use.
# The Command Line Tools sometimes carry a newer SDK than the compiler; we probe.
set -u
CACHE="${TMPDIR:-/tmp}/localmusic-sdk-path"
if [ -f "$CACHE" ] && [ -d "$(cat "$CACHE")" ]; then cat "$CACHE"; exit 0; fi
DEV_DIR="$(xcode-select -p 2>/dev/null || echo /Library/Developer/CommandLineTools)"
CANDIDATES=()
for d in "$DEV_DIR/Platforms/MacOSX.platform/Developer/SDKs" "$DEV_DIR/SDKs" /Library/Developer/CommandLineTools/SDKs; do
  [ -d "$d" ] || continue
  for s in "$d"/MacOSX*.sdk; do [ -d "$s" ] && [ ! -L "$s" ] && CANDIDATES+=("$s"); done
done
PROBE="$(mktemp -d)/probe.swift"
echo 'import SwiftUI; @main struct P: App { var body: some Scene { WindowGroup { Text("") } } }' > "$PROBE"
for s in $(printf '%s\n' "${CANDIDATES[@]}" | sort -rV); do
  if swiftc -sdk "$s" -parse-as-library -target arm64-apple-macosx14.0 -typecheck "$PROBE" >/dev/null 2>&1; then
    echo "$s" > "$CACHE"; echo "$s"; exit 0
  fi
done
echo "No usable macOS SDK found for $(swiftc --version 2>&1 | head -1)" >&2
exit 1

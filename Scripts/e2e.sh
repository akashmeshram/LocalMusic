#!/bin/bash
# End-to-end run of the real app against a throwaway profile with the mock downloader.
#   Scripts/e2e.sh            # all scenarios
#   Scripts/e2e.sh playback   # one scenario
#   E2E_NETWORK=1 Scripts/e2e.sh   # also run the live MusicBrainz scenario
set -uo pipefail
cd "$(dirname "$0")/.."
Scripts/build.sh debug >/dev/null || { echo "build failed"; exit 1; }
PROFILE="$(mktemp -d "${TMPDIR:-/tmp}/localmusic-e2e.XXXXXX")"
REPORT="$PROFILE/report.json"
SCENARIOS="${1:-all}"
START="$(date +%s)"
pkill -x LocalMusic 2>/dev/null; sleep 0.5
echo "▸ profile: $PROFILE"
"build/debug/LocalMusic.app/Contents/MacOS/LocalMusic" --mock "--profile=$PROFILE" "--e2e=$SCENARIOS" "--e2e-report=$REPORT" \
  "--e2e-network=${E2E_NETWORK:-0}" "--screenshot=$PROFILE/shots" 2>"$PROFILE/stderr.log"
CODE=$?
if [ $CODE -gt 1 ]; then
  echo "▸ APP CRASHED (exit $CODE)"
  sleep 2
  REPORT_IPS="$(ls -t ~/Library/Logs/DiagnosticReports/LocalMusic*.ips 2>/dev/null | head -1)"
  if [ -n "$REPORT_IPS" ] && [ "$(stat -f %m "$REPORT_IPS")" -ge "$START" ]; then
    python3 - "$REPORT_IPS" <<'PY'
import sys, json
d = json.loads(open(sys.argv[1]).read().split('\n', 1)[1])
print("  signal:", (d.get('exception') or {}).get('signal'), "|", d.get('asi'))
t = d['threads'][d.get('faultingThread', 0)]
for fr in t['frames'][:14]:
    img = d['usedImages'][fr['imageIndex']]['name'] if 'imageIndex' in fr else '?'
    print("   ", img, fr.get('symbol', ''), fr.get('sourceFile', ''), fr.get('sourceLine', ''))
PY
  fi
  grep -i "uncaught exception" "$HOME/Library/Logs/LocalMusic/LocalMusic.log" | tail -2
fi
echo "▸ exit code $CODE — report: $REPORT"
exit $CODE

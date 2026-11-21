#!/bin/bash
# Builds the debug app and opens it on the demo home, ready to record: fake folders only, the fake
# Applications folder, no grace period, a 1440 by 900 point window in the middle of the screen, no
# welcome, Desktop and Documents already on, and twelve weeks of past cleanups for the insights.
#
# Usage:
#   scripts/run-demo.sh            # builds the demo home the first time, then reuses it
#   scripts/run-demo.sh --reset    # puts the demo home and its activity log back as they started
#
# The demo home lives at $TMPDIR/SmartOSDemo (scripts/make-demo-home.sh). Its activity log is the
# debug build's own, kept apart from the real one; your Downloads, Desktop and Documents are never read.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DEMO="${TMPDIR:-/tmp}"; DEMO="${DEMO%/}/SmartOSDemo"
cd "$REPO"

if [ "${1:-}" = "--reset" ] || [ ! -f "$DEMO/.smartos-demo-home" ]; then
  scripts/make-demo-home.sh "$DEMO"
  LOG="$(xcrun swift scripts/demo-log-folder.swift "$DEMO/Home")"
  # Only the debug build's own log folder for this demo home, under the temporary directory.
  case "$LOG" in
    "${TMPDIR%/}"/com.quaden2307.SmartOSFileStore.debug/*|/private"${TMPDIR%/}"/com.quaden2307.SmartOSFileStore.debug/*) rm -rf "$LOG" ;;
    *) echo "run-demo: not removing an unexpected log folder: $LOG" >&2 ;;
  esac
fi

command -v xcodegen >/dev/null && xcodegen generate >/dev/null
xcodebuild -scheme SmartOSFileStore -destination 'platform=macOS' -derivedDataPath build build -quiet
pkill -f "Debug/SmartOSFileStore.app/Contents/MacOS/SmartOSFileStore" 2>/dev/null || true
open -n build/Build/Products/Debug/SmartOSFileStore.app --args \
  -DemoHome "$DEMO/Home" \
  -ApplicationsFolder "$DEMO/Applications" \
  -GracePeriodSeconds 0 \
  -WindowSize 1440x900 \
  -SkipWelcome \
  -TurnOnStandardFolders \
  -SeedDemoHistory
echo "Opened Smart OS File Store on the demo home: $DEMO/Home"

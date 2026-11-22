#!/bin/bash
# Runs the chat's evals on this Mac's on-device model (Apple Intelligence must be on) and writes
# the report to docs/evals/<date>-prompts-v<N>.md, with its row in docs/evals/README.md. Takes
# about twenty minutes. Nothing outside a temporary fake folder is read; nothing is changed.
#
# Usage:
#   scripts/run-evals.sh                                  # every eval: the scored run and the older fixed cases
#   scripts/run-evals.sh -only-testing:ChatEvals          # the scored run only
#
# The whole output is kept in build/evals.log.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
xcodegen generate --quiet
mkdir -p build
status=0
TEST_RUNNER_SMARTOS_EVAL_REPORT_DIR="$REPO/docs/evals" xcodebuild -scheme SmartOSFileStore -destination 'platform=macOS' \
  -configuration Release -derivedDataPath build test -testPlan Evals "$@" > build/evals.log 2>&1 || status=$?
grep -E "CHAT EVAL|✘|Test run with" build/evals.log || true
exit $status

#!/usr/bin/env bash
# run-all.sh — minimal aggregator for the hook fixture suite. Runs every hooks/tests/*.test.sh,
# tallies, prints `RESULT: N passed M failed`, exits non-zero on ANY failure. No framework (surgical).
# claude-doctor section 5 invokes this; before it existed, section 5 silently skipped.
#
# Each test is bounded by `timeout` WHEN AVAILABLE (GNU coreutils: present on Linux + MSYS Git-bash;
# ABSENT on stock macOS) so one slow/hung test can't wedge the gate — a timeout-kill (124) counts as a
# FAIL with a TIMED-OUT label. On macOS (no timeout) tests run unbounded (spawn is fast there, so the
# ~90s MSYS stop-dispatcher.test.sh wall is a non-issue). Budget override: AAL_TEST_TIMEOUT (default 300).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BUDGET="${AAL_TEST_TIMEOUT:-300}"
HAVE_TIMEOUT=0; command -v timeout >/dev/null 2>&1 && HAVE_TIMEOUT=1
PASS=0; FAIL=0; FAILED=""
for t in "$HERE"/*.test.sh; do
  [ -f "$t" ] || continue
  name=$(basename "$t")
  echo "===== $name ====="
  if [ "$HAVE_TIMEOUT" = 1 ]; then timeout "$BUDGET" bash "$t"; rc=$?; else bash "$t"; rc=$?; fi
  if [ "$rc" = 0 ]; then PASS=$((PASS+1))
  elif [ "$rc" = 124 ]; then FAIL=$((FAIL+1)); FAILED="$FAILED $name(TIMED-OUT>${BUDGET}s)"
  else FAIL=$((FAIL+1)); FAILED="$FAILED $name(rc=$rc)"; fi
  echo ""
done
echo "RESULT: $PASS passed, $FAIL failed${FAILED:+ —$FAILED}"
[ "$FAIL" -eq 0 ]

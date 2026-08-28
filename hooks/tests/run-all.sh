#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BUDGET="${AAL_TEST_TIMEOUT:-300}"
HAVE_TIMEOUT=0; command -v timeout >/dev/null 2>&1 && HAVE_TIMEOUT=1
PASS=0; FAIL=0; FAILED=""
# BOTH extensions. Globbing only *.test.sh let a .mjs fixture ship and never run — which is the
# same thing as not having it, while looking like coverage. The runner is chosen per file; a .mjs
# fixture handed to bash reports a shell syntax error that reads like a broken test.
for t in "$HERE"/*.test.sh "$HERE"/*.test.mjs; do
  [ -f "$t" ] || continue
  name=$(basename "$t")
  case "$name" in *.mjs) RUNNER=node ;; *) RUNNER=bash ;; esac
  echo "===== $name ====="
  if [ "$HAVE_TIMEOUT" = 1 ]; then timeout "$BUDGET" "$RUNNER" "$t"; rc=$?; else "$RUNNER" "$t"; rc=$?; fi
  if [ "$rc" = 0 ]; then PASS=$((PASS+1))
  elif [ "$rc" = 124 ]; then FAIL=$((FAIL+1)); FAILED="$FAILED $name(TIMED-OUT>${BUDGET}s)"
  else FAIL=$((FAIL+1)); FAILED="$FAILED $name(rc=$rc)"; fi
  echo ""
done
echo "RESULT: $PASS passed, $FAIL failed${FAILED:+ —$FAILED}"
[ "$FAIL" -eq 0 ]

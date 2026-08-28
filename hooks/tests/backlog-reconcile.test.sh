#!/usr/bin/env bash
set -u
REC="$(cd "$(dirname "$0")/.." && pwd)"/backlog-reconcile.mjs
# 🔴 Scratch lives in a temp dir the fixture creates and removes — NEVER under the operator's
# config root. Every path below is handed to the tool explicitly, so nothing requires it to sit
# there; with CLAUDE_CONFIG_DIR unset (the default for an adopter) the old form dropped files
# into a real ~/.claude, and on a machine where that directory is read-only source it is worse
# than untidy.
T="$(mktemp -d)/board.md"
PASS=0; FAIL=0; FAILURES=()
run(){ AAL_BACKLOG="$T" AAL_REPO="fixture-owner/does-not-exist-xyz" node "$REC" 2>&1; }
want(){ if printf '%s' "$2" | grep -qF -- "$3"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILURES+=("$1: want '$3'"); fi; }
absent(){ if printf '%s' "$2" | grep -qF -- "$3"; then FAIL=$((FAIL+1)); FAILURES+=("$1: must NOT have '$3'"); else PASS=$((PASS+1)); fi; }

printf '## ACTIVE\n\n### [QUEUED] R-real · P3\n- aliases: r-real\n\n### ✅ R-stray-done · DONE+LIVE-verified #99\n- aliases: r-stray\n' > "$T"
O=$(run)
want "1 bare-badge flagged"        "$O" '[bare-badge]'
want "1 bare-badge names the card" "$O" 'R-stray-done'

printf '## ACTIVE\n\n### [QUEUED] R-real · P3\n- aliases: r-real\n\n### [IN-DEV] R-two · P3\n- aliases: r-two\n' > "$T"
O=$(run)
absent "2 clean board → no bare-badge" "$O" '[bare-badge]'

printf '## 🚀 ACTIVE\n\n## 🔍 audit findings\n\n### [QUEUED] R-real · P3\n- aliases: r-real\n' > "$T"
O=$(run)
absent "3 h2 section header not flagged" "$O" '[bare-badge]'

rm -f "$T"
name="$(basename "$0")"
if [ "$FAIL" -eq 0 ]; then
  echo "  $name: PASS ($PASS/$PASS)"
  exit 0
else
  echo "  $name: FAIL ($PASS pass, $FAIL fail)"
  for f in "${FAILURES[@]}"; do echo "    - $f"; done
  exit 1
fi

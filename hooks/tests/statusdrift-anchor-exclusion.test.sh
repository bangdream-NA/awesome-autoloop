#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOKS_SRC="$(cd "$HERE/.." && pwd)"
GATE="$HOOKS_SRC/block-backlog-status-drift.mjs"
ARCH="/proj/.claude/BACKLOG-archive.md"

PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }
assert_empty()        { if [ -z "$2" ]; then ok "$1"; else bad "$1 — expected ALLOW (empty) | got: $2"; fi; }
assert_contains()     { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 — expected to contain: $3 | got: $2" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) bad "$1 — should NOT contain: $3 | got: $2" ;; *) ok "$1" ;; esac; }

run_edit() {
  local fp="$1" old="$2" nu="$3" payload
  payload=$(FP="$fp" OLD="$old" NU="$nu" node -e 'process.stdout.write(JSON.stringify({tool_name:"Edit",tool_input:{file_path:process.env.FP,old_string:process.env.OLD,new_string:process.env.NU}}))')
  printf '%s' "$payload" | node "$GATE" 2>/dev/null
}

echo "== archive DoD-gate anchor-exclusion (Y-8) =="

OUT=$(run_edit "$ARCH" \
  "### [DONE] R-anchor-neighbour" \
  "### [DONE] R-new-card · ARCHIVED DoD-VERIFIED @abc1234
- log: 2026-07-10 · shipped
### [DONE] R-anchor-neighbour")
assert_empty "RED truncated anchor + DoD-VERIFIED new card → ALLOW (anchor excluded)" "$OUT"

OUT=$(run_edit "$ARCH" \
  "### [DONE] R-anchor-neighbour · ARCHIVED DoD-VERIFIED @abc1234" \
  "### [DONE] R-teeth-new (MERGED #9)
- log: 2026-07-10 · x
### [DONE] R-anchor-neighbour · ARCHIVED DoD-VERIFIED @abc1234")
assert_contains     "GREEN-teeth DoD-less new card still → DENY (teeth intact)"      "$OUT" '"permissionDecision":"deny"'
assert_contains     "GREEN-teeth deny names the NEW card"                            "$OUT" "R-teeth-new"
assert_not_contains "GREEN-teeth deny does NOT name the excluded anchor"             "$OUT" "R-anchor-neighbour"

OUT=$(run_edit "$ARCH" \
  "## ARCHIVE (fixture)" \
  "### [DONE] R-solo-dodless (MERGED #9)
- log: 2026-07-10 · x")
assert_contains "GREEN-baseline DoD-less card, no anchor → DENY" "$OUT" '"permissionDecision":"deny"'

echo ""; echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

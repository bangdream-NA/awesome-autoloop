#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOKS_SRC="$(cd "$HERE/.." && pwd)"
GATE="$HOOKS_SRC/block-backlog-status-drift.mjs"
BOARD="/proj/.claude/BACKLOG.md"

PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }
assert_empty()    { if [ -z "$2" ]; then ok "$1"; else bad "$1 — expected ALLOW (empty) | got: $2"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 — expected to contain: $3 | got: $2" ;; esac; }

run_edit() {
  local fp="$1" old="$2" nu="$3" payload
  payload=$(FP="$fp" OLD="$old" NU="$nu" node -e 'process.stdout.write(JSON.stringify({tool_name:"Edit",tool_input:{file_path:process.env.FP,old_string:process.env.OLD,new_string:process.env.NU}}))')
  printf '%s' "$payload" | node "$GATE" 2>/dev/null
}

echo "== card-header DEMOTE guard (A0) =="

OUT=$(run_edit "$BOARD" \
  "### [IN-DEV] R-foo · P2" \
  "R-foo (MERGED #9) done
- log: 2026-07-10 · MERGED · archived")
assert_contains "RED de-prefix demote (keeps body) → DENY" "$OUT" "DEMOTE antipattern"
assert_contains "RED deny is a PreToolUse deny decision"   "$OUT" '"permissionDecision":"deny"'

OUT=$(run_edit "$BOARD" \
  "### [IN-DEV] R-foo · P2" \
  "### [REVIEW] R-foo · P2")
assert_empty "GREEN-keep [IN-DEV]→[REVIEW] (keeps ### header) → ALLOW" "$OUT"

OUT=$(run_edit "$BOARD" \
  "### [IN-DEV] R-foo · P2
- log: 2026-07-10 · x" \
  "")
assert_empty "GREEN-delete pure delete (empty new_string) → ALLOW" "$OUT"

OUT=$(run_edit "/proj/notes.md" \
  "### [IN-DEV] R-foo · P2" \
  "R-foo (MERGED #9) done
- log: archived")
assert_empty "GREEN-nonboard demote on notes.md → ALLOW (no-op)" "$OUT"

echo ""; echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

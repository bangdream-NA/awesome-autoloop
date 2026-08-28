#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$(cd "$HERE/.." && pwd)/block-audit-workflow-while-board-open.mjs"

PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }
assert_empty()    { if [ -z "$2" ]; then ok "$1"; else bad "$1 — expected ALLOW (empty) | got: $2"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 — expected to contain: $3 | got: $2" ;; esac; }

D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
OPEN="$D/open.md";  printf '# BACKLOG\n\n### [QUEUED] R-live-wave · P2\n- aliases: r-live-wave\n' > "$OPEN"
CLEAR="$D/clear.md"; printf '# BACKLOG\n\n(no active cards)\n' > "$CLEAR"

run() {
  local nm="$1" scr="$2" board="$3" payload
  payload=$(NM="$nm" SC="$scr" node -e 'process.stdout.write(JSON.stringify({tool_name:"Workflow",tool_input:{name:process.env.NM,script:process.env.SC}}))')
  printf '%s' "$payload" | env AAL_AUDITGATE_BACKLOG="$board" node "$GATE"
}

echo "== audit-workflow board-open gate (A-6) =="

OUT=$(run "full-site audit" "export const meta = { name: 'full-site audit', description: 'audit every page' };" "$OPEN")
assert_contains "RED audit Workflow + open board → DENY" "$OUT" "AUDIT-GATE"
assert_contains "RED deny names the offending card" "$OUT" "R-live-wave"

OUT=$(run "full-site audit" "export const meta = { name: 'full-site audit', description: 'audit every page' };" "$CLEAR")
assert_empty "GREEN audit Workflow + cleared board → ALLOW" "$OUT"

OUT=$(run "deploy pipeline" "export const meta = { name: 'deploy', description: 'ship the build' };" "$OPEN")
assert_empty "GREEN non-audit Workflow (open board) → ALLOW" "$OUT"

OUT=$(run "self-improve" "export const meta = { name: 'self-improve', description: 'review the struggle log' };
const src = 'struggle-log-audit-2026-05-28.md';" "$OPEN")
assert_empty "GREEN incidental 'audit' filename in body (meta clean) → ALLOW (meta-anchor)" "$OUT"

echo ""; echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

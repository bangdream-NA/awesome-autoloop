#!/usr/bin/env bash
# audit-workflow-board-open.test.sh — A-6. Proves block-audit-workflow-while-board-open.mjs denies an
# audit-shaped Workflow while the board has actionable [QUEUED]/[IN-DEV]/[REVIEW] cards, allows it on a
# cleared board, allows a non-audit Workflow, and (rule-8 meta-anchor) allows a non-audit Workflow whose
# SCRIPT BODY merely quotes an "audit" DATA filename — intent is judged on the declared identity + meta
# literal, not the whole script blob. Runs the .mjs directly with AAL_AUDITGATE_BACKLOG (test override).
# Toolchain: bash + node. Run: bash hooks/tests/audit-workflow-board-open.test.sh
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

# run <name> <script> <board> -> gate stdout (deny JSON or empty=allow)
run() {
  local nm="$1" scr="$2" board="$3" payload
  payload=$(NM="$nm" SC="$scr" node -e 'process.stdout.write(JSON.stringify({tool_name:"Workflow",tool_input:{name:process.env.NM,script:process.env.SC}}))')
  printf '%s' "$payload" | env AAL_AUDITGATE_BACKLOG="$board" node "$GATE"
}

echo "== audit-workflow board-open gate (A-6) =="

# RED: audit-shaped Workflow + board with an actionable [QUEUED] card → DENY.
OUT=$(run "full-site audit" "export const meta = { name: 'full-site audit', description: 'audit every page' };" "$OPEN")
assert_contains "RED audit Workflow + open board → DENY" "$OUT" "AUDIT-GATE"
assert_contains "RED deny names the offending card" "$OUT" "R-live-wave"

# GREEN-clear: the SAME audit Workflow on a CLEARED board (no actionable cards) → ALLOW.
OUT=$(run "full-site audit" "export const meta = { name: 'full-site audit', description: 'audit every page' };" "$CLEAR")
assert_empty "GREEN audit Workflow + cleared board → ALLOW" "$OUT"

# GREEN-nonaudit: a non-audit Workflow, board OPEN → ALLOW (not the gate's concern).
OUT=$(run "deploy pipeline" "export const meta = { name: 'deploy', description: 'ship the build' };" "$OPEN")
assert_empty "GREEN non-audit Workflow (open board) → ALLOW" "$OUT"

# GREEN-incidental-meta (rule-8): clean meta (non-audit), but the SCRIPT BODY quotes an 'audit' DATA
# filename. Intent = declared/meta only when meta parses → the incidental body 'audit' must NOT trigger.
OUT=$(run "self-improve" "export const meta = { name: 'self-improve', description: 'review the struggle log' };
const src = 'struggle-log-audit-2026-05-28.md';" "$OPEN")
assert_empty "GREEN incidental 'audit' filename in body (meta clean) → ALLOW (meta-anchor)" "$OUT"

echo ""; echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# planverdict-dev-jsonl.test.sh — AC-F5 (BLOCKER-1 proof). Proves the DEVELOPER dispatch gate
# (require-premise-verified-before-dev.sh → lib/premise-target.mjs) is jsonl-first via the shared
# lib/plan-verdict.mjs resolver, so a new-model wave (jsonl-only plan-review APPROVED, monolith
# absent) no longer DEADLOCKS the developer dispatch:
#   (a) jsonl APPROVED, monolith absent                          → ALLOW (GREEN — the fix)
#   (b) neither jsonl nor monolith has the wave                  → DENY (NOVERDICT, fail-closed)
#   (c) RED: a monolith-only-reverted premise-target.mjs (jsonl read removed) on the SAME jsonl-only
#       APPROVED input                                           → DENY (the deadlock WITHOUT the fix)
# The (a)-vs-(c) contrast on identical input IS the BLOCKER-1 RED→GREEN proof.
# Toolchain: bash + node. Self-contained temp dirs. Run: bash hooks/tests/planverdict-dev-jsonl.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOKS_SRC="$(cd "$HERE/.." && pwd)"
WRAP_SRC="$HOOKS_SRC/require-premise-verified-before-dev.sh"
PREMISE_SRC="$HOOKS_SRC/lib/premise-target.mjs"
WAVE="r-dev-jsonl-fix"

PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }
halt(){ echo ""; echo "RESULT: $PASS passed, $FAIL failed"; exit 1; }
assert_empty()    { if [ -z "$2" ]; then ok "$1"; else bad "$1 — expected ALLOW (empty) | got: $2"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 — expected to contain: $3 | got: $2" ;; esac; }

build_hookdir() {  # <dir> [premise_override]
  local d="$1"; local premise="${2:-$PREMISE_SRC}"
  mkdir -p "$d/lib"
  cp "$HOOKS_SRC/lib/activation.sh"    "$d/lib/activation.sh"
  cp "$HOOKS_SRC/lib/parse-json.sh"    "$d/lib/parse-json.sh"
  cp "$HOOKS_SRC/lib/plan-verdict.mjs" "$d/lib/plan-verdict.mjs"
  cp "$premise"                        "$d/lib/premise-target.mjs"
  cp "$WRAP_SRC" "$d/require-premise-verified-before-dev.sh"; chmod +x "$d/require-premise-verified-before-dev.sh"
}
mkproj() {  # <projdir>
  local d="$1"; mkdir -p "$d/.claude/reviews"; : > "$d/.claude/.autoloop"
  cat > "$d/.claude/BACKLOG.md" <<EOF
# BACKLOG (fixture)

### [IN-DEV] $WAVE · P2
- aliases: $WAVE
- problem: fixture card so the dev gate can resolve the target wave.
- fix: n/a
EOF
}
run_dev() {  # <hookdir> <projdir> -> wrapper stdout (deny JSON or empty=allow)
  local hd="$1" p="$2" payload
  payload=$(WV="$WAVE" node -e 'const w=process.env.WV;process.stdout.write(JSON.stringify({tool_name:"Agent",tool_input:{subagent_type:"developer",name:"dev-"+w,prompt:"developer for wave **"+w+"** to implement the locks"}}))')
  printf '%s' "$payload" | env AAL_GATES="pipeline-roles:" CLAUDE_PROJECT_DIR="$p" \
    AAL_BACKLOG="$p/.claude/BACKLOG.md" AAL_PLAN_REVIEWS="$p/.claude/plan-reviews.md" AAL_REVIEWS_JSONL="$p/.claude/reviews/index.jsonl" \
    bash "$hd/require-premise-verified-before-dev.sh" 2>/dev/null
}
jrow() { printf '{"plan":"%s","plan_sha":"abc1234","verdict":"%s","mode":"A","ts":"2026-07-10T00:00:00Z","reviewer":"pr"}\n' "$WAVE" "$1"; }

echo "== developer gate jsonl-first matrix (BLOCKER-1) =="

# ---- Build the monolith-only-REVERTED premise-target.mjs: awk-delete the jsonl-first block (the
#      `if (jsonlPath) { ... }` span) so it falls straight to the monolith presence-check = the
#      pre-fix behavior that DEADLOCKS a jsonl-only wave. ----
REVERTED=$(mktemp --suffix=.mjs 2>/dev/null || mktemp)
awk '
  /^  if \(jsonlPath\) \{$/ { skip=1; next }
  skip && /^  \}$/          { skip=0; next }
  !skip { print }
' "$PREMISE_SRC" > "$REVERTED"
# FAIL-LOUD GUARD 1: the swap took — the reverted mjs has NO jsonlPlanVerdict CALL, and node --check passes.
if ! grep -q 'jsonlPlanVerdict(jsonlPath' "$REVERTED" && node --check "$REVERTED" 2>/dev/null; then
  ok "SETUP: monolith-only-reverted premise-target.mjs built (no jsonl call, parses)"
else bad "SETUP: revert swap did NOT take / does not parse (halt)"; halt; fi

# (a) GREEN — real hook: jsonl APPROVED, monolith absent → ALLOW (the BLOCKER-1 fix).
DGA=$(mktemp -d); build_hookdir "$DGA"; PGA="$DGA/proj"; mkproj "$PGA"; jrow APPROVED > "$PGA/.claude/reviews/index.jsonl"
OUT=$(run_dev "$DGA" "$PGA")
assert_empty "(a) GREEN real hook: jsonl-only APPROVED → ALLOW (no monolith needed)" "$OUT"

# (b) neither jsonl nor monolith has the wave → DENY (NOVERDICT). Fail-loud: the deny is the
#     NOVERDICT reason, proving the wave RESOLVED (not the NOWAVE 'could not identify' path).
DGB=$(mktemp -d); build_hookdir "$DGB"; PGB="$DGB/proj"; mkproj "$PGB"; : > "$PGB/.claude/reviews/index.jsonl"
OUT=$(run_dev "$DGB" "$PGB")
assert_contains "(b) no verdict anywhere → DENY" "$OUT" '"permissionDecision":"deny"'
assert_contains "(b) DENY is NOVERDICT (wave RESOLVED, not NOWAVE)" "$OUT" "NO logged plan-review verdict"

# (c) RED — monolith-only-reverted hook on the SAME jsonl-only APPROVED input → DENY (deadlock).
DRC=$(mktemp -d); build_hookdir "$DRC" "$REVERTED"; PRC="$DRC/proj"; mkproj "$PRC"; jrow APPROVED > "$PRC/.claude/reviews/index.jsonl"
OUT=$(run_dev "$DRC" "$PRC")
assert_contains "(c) RED reverted hook DEADLOCKS a jsonl-only APPROVED wave → DENY (matrix inverts vs (a))" "$OUT" '"permissionDecision":"deny"'

rm -rf "$DGA" "$DGB" "$DRC"; rm -f "$REVERTED"
echo ""; echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

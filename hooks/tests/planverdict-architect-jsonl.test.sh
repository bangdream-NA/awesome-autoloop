#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOKS_SRC="$(cd "$HERE/.." && pwd)"
GATE="$HOOKS_SRC/backlog-sop-validate.mjs"
WAVE="r-arch-jsonl-fix"

PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }
halt(){ echo ""; echo "RESULT: $PASS passed, $FAIL failed"; exit 1; }
assert_empty()        { if [ -z "$2" ]; then ok "$1"; else bad "$1 — expected ALLOW (empty) | got: $2"; fi; }
assert_contains()     { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 — expected to contain: $3 | got: $2" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) bad "$1 — should NOT contain: $3 | got: $2" ;; *) ok "$1" ;; esac; }

mkproj() {
  local d="$1"; mkdir -p "$d/reviews"
  cat > "$d/BACKLOG.md" <<EOF
# BACKLOG (fixture)

### [QUEUED] $WAVE · P2
- aliases: $WAVE
- problem: fixture card so the architect gate can resolve the target wave.
- fix: n/a
EOF
}
run_arch() {
  local d="$1" payload
  payload=$(WV="$WAVE" node -e 'const w=process.env.WV;process.stdout.write(JSON.stringify({tool_name:"Agent",tool_input:{subagent_type:"architect",name:"arch-"+w,prompt:"architect for wave **"+w+"** to lock the implementation spec"}}))')
  printf '%s' "$payload" | env AAL_GATES="pipeline-roles:" AAL_NO_GH=1 \
    AAL_BACKLOG="$d/BACKLOG.md" AAL_PLAN_REVIEWS="$d/plan-reviews.md" AAL_REVIEWS_JSONL="$d/reviews/index.jsonl" \
    node "$GATE" --mode pre-dispatch 2>/dev/null
}
jrow() { printf '{"plan":"%s","plan_sha":"abc1234","verdict":"%s","mode":"A","ts":"2026-07-10T00:00:00Z","reviewer":"pr"}' "$WAVE" "$1"; }

echo "== architect gate jsonl-first matrix =="

DS=$(mktemp -d); mkproj "$DS"
OUT=$(run_arch "$DS")
assert_contains     "SETUP: no-verdict deny cites the plan-review reason (card resolves cleanly)" "$OUT" "NO APPROVED plan-review verdict"
assert_not_contains "SETUP: not a 'no active card' deny"    "$OUT" "no active BACKLOG card"
assert_not_contains "SETUP: not a 'status not in' deny"     "$OUT" "not in {"
rm -rf "$DS"

DA=$(mktemp -d); mkproj "$DA"; jrow APPROVED > "$DA/reviews/index.jsonl"
OUT=$(run_arch "$DA")
assert_empty "(a) jsonl APPROVED (no monolith) → ALLOW (empty stdout)" "$OUT"
rm -rf "$DA"

DB=$(mktemp -d); mkproj "$DB"; jrow NEEDS_REVISION > "$DB/reviews/index.jsonl"
cat > "$DB/plan-reviews.md" <<EOF
# Plan reviews

## Plan review: $WAVE @abc1234
- Verdict: APPROVED
EOF
OUT=$(run_arch "$DB")
assert_contains "(b) jsonl NEEDS_REVISION beats stale monolith APPROVED → DENY (stricter)" "$OUT" '"permissionDecision":"deny"'
assert_contains "(b) deny is the plan-review reason (not a card/status deny)"               "$OUT" "NO APPROVED plan-review verdict"
rm -rf "$DB"

DC=$(mktemp -d); mkproj "$DC"
{ jrow APPROVED; jrow APPROVED; printf '\n'; } > "$DC/reviews/index.jsonl"
LC=$(grep -c . "$DC/reviews/index.jsonl"); OBJ=$(grep -o '"mode":"A"' "$DC/reviews/index.jsonl" | grep -c .)
{ [ "$LC" = "1" ] && [ "$OBJ" = "2" ]; } && ok "(c) SETUP: seed is ONE physical line carrying TWO fused objects" || { bad "(c) SETUP: fused seed wrong (lines=$LC objs=$OBJ) (halt)"; halt; }
OUT=$(run_arch "$DC")
assert_contains "(c) FUSED APPROVED is SKIPPED (parse-guard) → DENY, no silent wrong-verdict pass" "$OUT" '"permissionDecision":"deny"'
{ jrow APPROVED; printf '\n'; jrow APPROVED; printf '\n'; } > "$DC/reviews/index.jsonl"
OUT=$(run_arch "$DC")
assert_empty "(c) un-fused: a newline-terminated APPROVED line parses → ALLOW (fused-ness was the only diff)" "$OUT"
rm -rf "$DC"

echo ""; echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

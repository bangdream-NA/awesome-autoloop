#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOKS_SRC="$(cd "$HERE/.." && pwd)"
GATE="$HOOKS_SRC/backlog-sop-validate.mjs"
WAVE="r-cardpr-anchor"

PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }
assert_empty()        { if [ -z "$2" ]; then ok "$1"; else bad "$1 — expected ALLOW (empty) | got: $2"; fi; }
assert_contains()     { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 — expected to contain: $3 | got: $2" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) bad "$1 — should NOT contain: $3 | got: $2" ;; *) ok "$1" ;; esac; }

mkboard() {
  local d="$1"; shift
  mkdir -p "$d/reviews"
  {
    printf '# BACKLOG (fixture)\n\n'
    printf '### [IN-DEV] %s · P2\n' "$WAVE"
    printf -- '- aliases: %s\n' "$WAVE"
    printf -- '- problem: fixture card so the reviewer gate can resolve the target wave.\n'
    printf -- '- fix: n/a\n'
    for l in "$@"; do printf -- '%s\n' "$l"; done
  } > "$d/BACKLOG.md"
}

run_review() {
  local d="$1" prompt="$2" payload
  payload=$(P="$prompt" node -e 'process.stdout.write(JSON.stringify({tool_name:"Agent",tool_input:{subagent_type:"code-reviewer",name:"reviewer-x",prompt:process.env.P}}))')
  printf '%s' "$payload" | env AAL_GATES="pipeline-roles:" AAL_NO_GH=1 \
    AAL_BACKLOG="$d/BACKLOG.md" AAL_PLAN_REVIEWS="$d/plan-reviews.md" AAL_REVIEWS_JSONL="$d/reviews/index.jsonl" \
    node "$GATE" --mode pre-review 2>/dev/null
}

NOPR_PROMPT="code-reviewer for wave **$WAVE** — Mode B review of the open request"

echo "== cardPR arrow-anchor matrix (B1) =="

DR=$(mktemp -d); mkboard "$DR" \
  '- log: 2026-07-10 · DEV_DELIVERED · dev · proof=green tests' \
  '- note: this fixes the regression from PR #500'
OUT=$(run_review "$DR" "$NOPR_PROMPT")
assert_contains     "RED-1 incidental 'from PR #500' → DENY (no false-allow)" "$OUT" "no OPEN PR found"
assert_not_contains "RED-1 SETUP: not a 'no active card' deny (card resolves)" "$OUT" "no active BACKLOG card"
assert_not_contains "RED-1 SETUP: not a 'status not in' deny"                  "$OUT" "not in {"
rm -rf "$DR"

DG1=$(mktemp -d); mkboard "$DG1" \
  '- log: 2026-07-10 · DEV_DELIVERED · dev · proof=green · pushed → PR #9'
OUT=$(run_review "$DG1" "$NOPR_PROMPT")
assert_empty "GREEN-1 'pushed → PR #9' arrow form → ALLOW (empty)" "$OUT"
rm -rf "$DG1"

DG1b=$(mktemp -d); mkboard "$DG1b" \
  '- log: 2026-07-10 · DEV_DELIVERED · dev · proof=green · pushed -> PR #9'
OUT=$(run_review "$DG1b" "$NOPR_PROMPT")
assert_empty "GREEN-1b 'pushed -> PR #9' ASCII-arrow form → ALLOW (empty)" "$OUT"
rm -rf "$DG1b"

DG2=$(mktemp -d); mkboard "$DG2" \
  '- log: 2026-07-10 · DEV_DELIVERED · dev · proof=green' \
  '- log: 2026-07-10 · PR_OPENED · dev · proof=pushed · #9'
OUT=$(run_review "$DG2" "$NOPR_PROMPT")
assert_empty "GREEN-2 '· PR_OPENED ·' marker → ALLOW (empty)" "$OUT"
rm -rf "$DG2"

DG3=$(mktemp -d); mkboard "$DG3" \
  '- log: 2026-07-10 · DEV_DELIVERED · dev · proof=green' \
  '- note: (MERGED #5 @abc1234)'
OUT=$(run_review "$DG3" "$NOPR_PROMPT")
assert_empty "GREEN-3 'MERGED #5' marker → ALLOW (empty)" "$OUT"
rm -rf "$DG3"

DC=$(mktemp -d); mkboard "$DC" \
  '- log: 2026-07-10 · DEV_DELIVERED · dev · proof=green tests' \
  '- note: this fixes the regression from PR #500'
OUT=$(run_review "$DC" "code-reviewer for wave **$WAVE** — Mode B, PR #500, HEAD @abc1234ff")
assert_empty "CONTROL path2 (real PR# + pinned SHA in dispatch) → ALLOW (empty)" "$OUT"
rm -rf "$DC"

echo ""; echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

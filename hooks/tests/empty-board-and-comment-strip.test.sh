#!/usr/bin/env bash
# empty-board-and-comment-strip.test.sh — R-empty-board-gate-mirror.
# Locks the two-state guard split (missing board FILE → no-op / readable board with ZERO active cards
# → DENY) at BOTH dispatch gates, the kit-English 'ZERO active cards' deny that TEACHES register-first,
# AND the parseCards HTML-comment strip (a `### [` example inside <!-- --> is not counted). Includes a
# RED→GREEN broken-gate proof (restore the OR-guard + revert the strip → the empty-board + template
# fixtures must FAIL) and a direct unit test of lib/strip-html-comments across the AC9 boundaries.
# Toolchain: bash + node only; bash-3.2-safe (portable constructs only — no bash-4-isms). Models:
# planverdict-architect-jsonl.test.sh (Agent-payload-on-stdin + AAL_* env vs the REAL .mjs) +
# deny-gate-crash-allow.test.sh (temp broken-copy with lib deps + sed + rm).
# Run: bash hooks/tests/empty-board-and-comment-strip.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOKS_SRC="$(cd "$HERE/.." && pwd)"
GATE="$HOOKS_SRC/backlog-sop-validate.mjs"
TEMPLATE="$(cd "$HOOKS_SRC/.." && pwd)/templates/BACKLOG.md"

PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }
halt(){ echo ""; echo "RESULT: $PASS passed, $FAIL failed"; exit 1; }
assert_empty()        { if [ -z "$2" ]; then ok "$1"; else bad "$1 — expected ALLOW (empty) | got: [$2]"; fi; }
assert_contains()     { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 — expected to contain: [$3] | got: [$2]" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) bad "$1 — should NOT contain: [$3] | got: [$2]" ;; *) ok "$1" ;; esac; }

DENY='"permissionDecision":"deny"'
ZERO='ZERO active cards'
WV="r-fixture-wave"

# ---- board writers (temp autoloop project dirs) --------------------------------------------------
# truly-empty board: headings only, NO `### [` header anywhere (0 cards WITH or WITHOUT the strip) —
# isolates the GUARD-split fix (AC1/AC2/AC4 + RED-A).
mkboard_bare() { local d="$1"; mkdir -p "$d/reviews"; cat > "$d/BACKLOG.md" <<'EOF'
# Task Backlog

## ACTIVE
EOF
}
# board with ONE real (out-of-comment) QUEUED card for $2=wave.
mkboard_card() { local d="$1" w="$2"; mkdir -p "$d/reviews"; cat > "$d/BACKLOG.md" <<EOF
# Task Backlog

## ACTIVE

### [QUEUED] $w · P2
- aliases: $w
- problem: fixture card so the gate can resolve the target wave.
- fix: n/a
EOF
}
# board whose ONLY `### [` card sits INSIDE a <!-- --> comment for $2=wave (0 cards only AFTER strip).
mkboard_card_in_comment() { local d="$1" w="$2"; mkdir -p "$d/reviews"; cat > "$d/BACKLOG.md" <<EOF
# Task Backlog

## ACTIVE

<!--
### [QUEUED] $w · P2
- aliases: $w
-->
EOF
}

# ---- gate runners (single-line Agent JSON payload → gate stdin; capture STDOUT only) -------------
run_pd() { # <dir> <role> <name> <wave> -> pre-dispatch stdout (deny JSON | empty=allow)
  local d="$1" role="$2" nm="$3" w="$4" payload
  payload=$(R="$role" N="$nm" W="$w" node -e 'process.stdout.write(JSON.stringify({tool_name:"Agent",tool_input:{subagent_type:process.env.R,name:process.env.N,prompt:"dispatch for wave **"+process.env.W+"** to do the work"}}))')
  printf '%s' "$payload" | env AAL_NO_GH=1 AAL_BACKLOG="$d/BACKLOG.md" \
    AAL_PLAN_REVIEWS="$d/plan-reviews.md" AAL_REVIEWS_JSONL="$d/reviews/index.jsonl" \
    node "$GATE" --mode pre-dispatch 2>/dev/null
}
run_pr() { # <dir> <role> <name> <wave> -> pre-review stdout
  local d="$1" role="$2" nm="$3" w="$4" payload
  payload=$(R="$role" N="$nm" W="$w" node -e 'process.stdout.write(JSON.stringify({tool_name:"Agent",tool_input:{subagent_type:process.env.R,name:process.env.N,prompt:"code-reviewer for wave **"+process.env.W+"** of the PR"}}))')
  printf '%s' "$payload" | env AAL_NO_GH=1 AAL_BACKLOG="$d/BACKLOG.md" \
    AAL_PLAN_REVIEWS="$d/plan-reviews.md" AAL_REVIEWS_JSONL="$d/reviews/index.jsonl" \
    node "$GATE" --mode pre-review 2>/dev/null
}
report_line1() { AAL_NO_GH=1 AAL_BACKLOG="$1" node "$GATE" --mode report 2>/dev/null | head -1; }

echo "== empty-board guard split (both modes, both directions) =="

# AC1/AC2 — MISSING board file → no-op (allow), both modes.
NOFILE=$(mktemp -d "$HOME/.aal-ebg-XXXXXX"); mkdir -p "$NOFILE/reviews"; rm -f "$NOFILE/BACKLOG.md"
assert_empty "AC1 pre-dispatch: MISSING board file → ALLOW (foreign-repo no-op)" "$(run_pd "$NOFILE" planner planner-$WV "$WV")"
assert_empty "AC2 pre-review:   MISSING board file → ALLOW (foreign-repo no-op)" "$(run_pr "$NOFILE" code-reviewer reviewer-$WV "$WV")"
rm -rf "$NOFILE"

# AC1/AC2 — readable-but-EMPTY board → DENY 'ZERO active cards', both modes.
DE=$(mktemp -d "$HOME/.aal-ebg-XXXXXX"); mkboard_bare "$DE"
PDE=$(run_pd "$DE" planner planner-$WV "$WV")
assert_contains "AC1 pre-dispatch: readable-EMPTY board → DENY"       "$PDE" "$DENY"
assert_contains "AC1 pre-dispatch: deny carries the greppable token"  "$PDE" "$ZERO"
PRE=$(run_pr "$DE" code-reviewer reviewer-$WV "$WV")
assert_contains "AC2 pre-review:   readable-EMPTY board → DENY"       "$PRE" "$DENY"
assert_contains "AC2 pre-review:   deny carries the greppable token"  "$PRE" "$ZERO"

# AC3 — the deny TEACHES the kit English skeleton + cites the board path (no leaked Chinese).
assert_contains     "AC3 pre-dispatch deny teaches the card skeleton (### [)"  "$PDE" "### ["
assert_contains     "AC3 pre-dispatch deny teaches the English aliases: field" "$PDE" "aliases:"
assert_contains     "AC3 pre-dispatch deny cites the resolved board path"      "$PDE" "$(basename "$DE")/BACKLOG.md"
assert_not_contains "AC3 pre-dispatch deny leaks NO Chinese 别名 field"         "$PDE" "别名"
assert_contains     "AC3 pre-review deny teaches the card skeleton (### [)"     "$PRE" "### ["
assert_not_contains "AC3 pre-review deny leaks NO Chinese 修复 field"           "$PRE" "修复"
rm -rf "$DE"

echo "== AC4 code-reviewer single-deny-at-right-stage =="
DC=$(mktemp -d "$HOME/.aal-ebg-XXXXXX"); mkboard_bare "$DC"
assert_empty    "AC4 code-reviewer at pre-dispatch on empty board → ALLOW (handed to pre-review)"    "$(run_pd "$DC" code-reviewer reviewer-$WV "$WV")"
assert_contains "AC4 code-reviewer at pre-review  on empty board → DENY (the single deny lands here)" "$(run_pr "$DC" code-reviewer reviewer-$WV "$WV")" "$ZERO"
rm -rf "$DC"

echo "== AC8 a real registered card still passes =="
DK=$(mktemp -d "$HOME/.aal-ebg-XXXXXX"); mkboard_card "$DK" "$WV"
assert_empty "AC8 pre-dispatch: readable board w/ a valid QUEUED card → ALLOW (planner)" "$(run_pd "$DK" planner planner-$WV "$WV")"
rm -rf "$DK"

echo "== AC9 comment-strip both-ways + verbatim template =="
DIC=$(mktemp -d "$HOME/.aal-ebg-XXXXXX"); mkboard_card_in_comment "$DIC" "$WV"
assert_contains "AC9 card INSIDE <!-- --> is NOT counted → empty-board DENY" "$(run_pd "$DIC" planner planner-$WV "$WV")" "$ZERO"
rm -rf "$DIC"
DOC=$(mktemp -d "$HOME/.aal-ebg-XXXXXX"); mkboard_card "$DOC" "$WV"
assert_empty "AC9 SAME card OUTSIDE any comment IS counted → ALLOW (strip is comment-scoped, not blanket)" "$(run_pd "$DOC" planner planner-$WV "$WV")"
rm -rf "$DOC"
assert_contains "AC9 verbatim templates/BACKLOG.md → 0 active cards (was 1 pre-fix)" "$(report_line1 "$TEMPLATE")" "0 active cards"

echo "== lib/strip-html-comments unit (AC9 boundaries) =="
# probe <input> -> "HASCARD|NOCARD lines=<n>" (does a ^### survive the strip; is the line count stable)
probe() { ( cd "$HOOKS_SRC/lib" && IN="$1" node --input-type=module -e '
  import { stripHtmlComments } from "./strip-html-comments.mjs";
  const s = stripHtmlComments(process.env.IN);
  process.stdout.write((/^###/m.test(s) ? "HASCARD" : "NOCARD") + " lines=" + s.split(/\n/).length);
' ); }
assert_contains "helper (a) multi-line comment strips the in-comment ### card" "$(probe $'x\n<!--\n### [QUEUED] R-x P2\n-->\ny')" "NOCARD"
assert_contains "helper (b) out-of-comment ### card survives (comment-scoped)" "$(probe '### [QUEUED] R-x P2')" "HASCARD"
assert_contains "helper (c) unclosed <!-- to EOF strips the trailing card (no crash)" "$(probe $'<!-- open\n### [QUEUED] R-x P2')" "NOCARD"
assert_contains "helper (d) same-line --> ### [x] leaves leading WS → NOT a card" "$(probe '<!-- c --> ### [QUEUED] R-x P2')" "NOCARD"
assert_contains "helper (e) preserves newlines (line count stable at 6)" "$(probe $'a\n<!--\nb\nc\n-->\nd')" "lines=6"
NULLRES=$( cd "$HOOKS_SRC/lib" && node --input-type=module -e 'import { stripHtmlComments } from "./strip-html-comments.mjs"; process.stdout.write(JSON.stringify(stripHtmlComments(null)))' )
assert_contains "helper null → empty string (no throw)" "$NULLRES" '""'

echo "== RED→GREEN broken-gate proof =="
# build a pre-wave copy: OR-guard restored + comment-strip reverted, with lib deps, in a temp dir.
build_broken() {
  local d; d="$(mktemp -d "$HOME/.aal-ebg-BROKEN-XXXXXX")"; mkdir -p "$d/lib"
  cp "$HOOKS_SRC/lib/plan-verdict.mjs"        "$d/lib/plan-verdict.mjs"
  cp "$HOOKS_SRC/lib/strip-html-comments.mjs" "$d/lib/strip-html-comments.mjs"
  sed -e 's#if (rd(BACKLOG) === null) process.exit(0);#if (rd(BACKLOG) === null || cards.length === 0) process.exit(0);#' \
      -e 's#splitL(stripHtmlComments(rd(boardFile)))#splitL(rd(boardFile))#' \
      "$GATE" > "$d/backlog-sop-validate.mjs"
  printf '%s' "$d/backlog-sop-validate.mjs"
}
BROKEN=$(build_broken); BDIR=$(dirname "$BROKEN")
grep -q 'rd(BACKLOG) === null || cards.length === 0' "$BROKEN" && ok "RED setup: OR-guard restored" || { bad "RED setup: OR-guard NOT restored — vacuous"; halt; }
grep -q 'splitL(rd(boardFile))'                       "$BROKEN" && ok "RED setup: comment-strip reverted" || { bad "RED setup: strip NOT reverted — vacuous"; halt; }
# RED-A: broken (OR-guard) + a truly-empty board → NO deny (proves the split fix is what denies).
DBR=$(mktemp -d "$HOME/.aal-ebg-XXXXXX"); mkboard_bare "$DBR"
RPAY=$(R=planner N=planner-$WV W=$WV node -e 'process.stdout.write(JSON.stringify({tool_name:"Agent",tool_input:{subagent_type:process.env.R,name:process.env.N,prompt:"dispatch for wave **"+process.env.W+"**"}}))')
RED_A=$(printf '%s' "$RPAY" | env AAL_NO_GH=1 AAL_BACKLOG="$DBR/BACKLOG.md" AAL_PLAN_REVIEWS="$DBR/plan-reviews.md" AAL_REVIEWS_JSONL="$DBR/reviews/index.jsonl" node "$BROKEN" --mode pre-dispatch 2>/dev/null)
assert_empty "RED-A: pre-wave OR-guard copy does NOT deny an empty board (the bug the split closes)" "$RED_A"
rm -rf "$DBR"
# RED-B: broken (no strip) + verbatim template report → 1 active card (proves the strip zeroes it).
RED_B=$(AAL_NO_GH=1 AAL_BACKLOG="$TEMPLATE" node "$BROKEN" --mode report 2>/dev/null | head -1)
assert_contains "RED-B: no-strip copy counts the commented template example as 1 active card" "$RED_B" "1 active cards"
rm -rf "$BDIR"
# GREEN companions are asserted above (empty-board DENY on the real gate + template 0 active cards).

echo ""; echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

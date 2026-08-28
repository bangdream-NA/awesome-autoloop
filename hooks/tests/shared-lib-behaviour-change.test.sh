#!/usr/bin/env bash
# AC8f — the population is NOT the 35 ported libraries. AC8f's words are "every ported library THAT
# CHANGES A GATE'S BEHAVIOUR", and a gate whose behaviour can change is one that ALREADY SHIPS. Of
# the 7 libraries that shipped before this wave, exactly TWO had their MATCHING altered:
#   hooks/lib/premise-target.mjs  — the board alias line: bilingual + full-width -> English ASCII
#   hooks/lib/verdict.sh          — the verdict marker: matched via ASCII normalisation
# Both halves of each are asserted: the capability that was DROPPED is gone, and the capability that
# was KEPT still works. A change that only removes is half-tested.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$(cd "$HERE/.." && pwd)/lib"

PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }

command -v node >/dev/null 2>&1 || { echo "  [FAIL] node absent — this fixture cannot run"; exit 1; }

FW_COLON=$(printf '\357\274\232')
FW_COMMA=$(printf '\357\274\214')
CN_ALIAS=$(printf '\345\210\253\345\220\215')

echo "== lib/verdict.sh — the verdict MARKER keeps its full-width tolerance, by ASCII normalisation =="
# shellcheck source=/dev/null
. "$LIB/verdict.sh"

OUT=$(printf 'VERDICT: APPROVED\n' | decide_verdict)
[ "$OUT" = "APPROVED" ] && ok "ASCII colon marker still parses -> $OUT" || bad "ASCII colon marker: expected APPROVED, got [$OUT]"

OUT=$(printf 'VERDICT%s APPROVED\n' "$FW_COLON" | decide_verdict)
[ "$OUT" = "APPROVED" ] && ok "FULL-WIDTH colon marker STILL parses (the preserved tolerance) -> $OUT" || bad "full-width colon marker: expected APPROVED, got [$OUT]"

OUT=$(printf 'VERDICT%s CHANGES_REQUESTED\n' "$FW_COLON" | decide_verdict)
case "$OUT" in DENY:*) ok "FULL-WIDTH colon marker classifies a REJECTION too (not just APPROVED)" ;; *) bad "full-width rejection: expected DENY:*, got [$OUT]" ;; esac

OUT=$(printf 'round 1 was APPROVED\n' | decide_verdict)
[ "$OUT" = "NONE" ] && ok "prose mentioning APPROVED is still NOT a candidate (teeth intact)" || bad "prose: expected NONE, got [$OUT]"

if grep -qF "$FW_COLON" "$LIB/verdict.sh"; then
  bad "verdict.sh still carries a full-width colon CODEPOINT in source (AC3a)"
else
  ok "verdict.sh carries NO full-width colon codepoint in source — tolerance without the character"
fi

echo ""
echo "== lib/premise-target.mjs — the board alias line is English ASCII only =="
D=$(mktemp -d "$HOME/.aal-8f-XXXXXX")
trap 'rm -rf "$D"' EXIT

# premise-target.mjs is a SCRIPT, not a module: it reads the hook payload on stdin and prints
# `OK` or `NOVERDICT<TAB><target>`. Drive it the way its only consumer does — this is the library's
# real interface, and a fixture that reached past it into an unexported function would be testing
# something no gate calls.
mkboard() { printf '%s\n' "$2" > "$D/BACKLOG.md"; }
# The plan-reviews ledger names the HEADER slug only. So `OK` can be reached ONLY by resolving the
# dispatched ALIAS through the board's alias line — which makes this arm a direct test of that line.
printf '## Plan review: r-parity-kit-english\nVERDICT: APPROVED\n' > "$D/plan-reviews.md"
resolve() {
  printf '%s' "{\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"developer\",\"team_name\":\"$1\",\"prompt\":\"work the $1 wave\"}}" \
    | AAL_BACKLOG="$D/BACKLOG.md" AAL_PLAN_REVIEWS="$D/plan-reviews.md" AAL_REVIEWS_JSONL="$D/nope.jsonl" \
      node "$LIB/premise-target.mjs" 2>/dev/null
}

mkboard x "### [QUEUED] R-parity-kit-english
- aliases: r-parity-kit-english, r-kit-english-rebuild
- problem: x"
OUT=$(resolve "r-kit-english-rebuild")
[ "$OUT" = "OK" ] && ok "ENGLISH \`- aliases:\` with an ASCII comma resolves the dispatched alias -> [$OUT]" || bad "English aliases: expected OK, got [$OUT]"

mkboard x "### [QUEUED] R-parity-kit-english
- ${CN_ALIAS}: r-parity-kit-english, r-kit-english-rebuild
- problem: x"
OUT=$(resolve "r-kit-english-rebuild")
case "$OUT" in NOVERDICT*) ok "the CHINESE alias field is NO LONGER recognised (the dropped capability, asserted)" ;; *) bad "Chinese alias field still resolved: [$OUT]" ;; esac

mkboard x "### [QUEUED] R-parity-kit-english
- aliases: r-parity-kit-english${FW_COMMA} r-kit-english-rebuild
- problem: x"
OUT=$(resolve "r-kit-english-rebuild")
# must-GREEN, and it documents the change's real BLAST RADIUS. Dropping the full-width comma from
# the split changes TOKENISATION, not resolvability on this path: with a full-width separator the
# alias line yields ONE token instead of two, but the card still matches on its header slug, so the
# gate still resolves. Asserted as GREEN on purpose — the first version of this arm expected
# NOVERDICT and went red against correct code, because it assumed the split was the only route.
case "$OUT" in OK) ok "a FULL-WIDTH comma separator still RESOLVES (via the header slug) — the drop changed tokenisation, not resolvability" ;; *) bad "full-width comma line no longer resolves at all — the drop was stricter than intended: [$OUT]" ;; esac

if grep -qF "$CN_ALIAS" "$LIB/premise-target.mjs" || grep -qF "$FW_COMMA" "$LIB/premise-target.mjs"; then
  bad "premise-target.mjs still carries a board-dialect CJK codepoint in source (AC3a)"
else
  ok "premise-target.mjs carries no board-dialect CJK codepoint in source"
fi

echo ""
echo "RESULT: $PASS passed, $FAIL failed (arms run: $((PASS+FAIL)))"
[ "$FAIL" -eq 0 ]

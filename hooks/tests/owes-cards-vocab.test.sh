#!/usr/bin/env bash
# ADMITS_DEFERRAL in hooks/require-owes-cards-cleared-before-verified.mjs, after English-isation.
#
# Direction of the edit: the source-language alternates were SUBTRACTED, and two senses English
# lacked were ADDED - "needs a <qualifier> card" and "handed off to a card". A must-red only ever
# answers "did the subtraction break it"; the addition fails by OVER-firing, because the source
# language had one word for a board card while English also spells a payment card and a card
# reader the same way. So each added alternation is a PAIR: D<n> must BLOCK, G<n> must stay SILENT
# on the nearest legitimate sentence.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$(cd "$HERE/.." && pwd)/require-owes-cards-cleared-before-verified.mjs"

TD="$(mktemp -d)"
NODE_TD="$TD"
if command -v cygpath >/dev/null 2>&1; then NODE_TD="$(cygpath -m "$TD")"; fi
export AAL_GATE_DENIALS_OFF=1

PASS=0; FAIL=0; FAILURES=()

# The header the write introduces. It satisfies every check that runs BEFORE the vocabulary one,
# so a verdict here is about ADMITS_DEFERRAL and nothing else.
HDR='### [DONE] R-source-card · P2 · DoD-VERIFIED · PURPOSE-REMEASURED: [1/1] the partition count on the live index ⇒ 0 today, against 31 on the card'

# The `# BACKLOG` title line is not decoration: the gate builds its known-card set by splitting on
# "\n### ", so a file whose FIRST line is a card header contributes zero known cards and the gate
# allows unconditionally. Real boards open with a title; a fixture that does not is testing the
# early return instead of the branch it names.
board() { # $1 = the body sentence under test
  printf '# BACKLOG\n\n%s\n- aliases: r-source-card\n- problem: 31 partitions were missing lastmod on the live index\n- fix: %s\n' \
    '### [REVIEW] R-source-card · P2' "$1" > "$TD/BACKLOG.md"
}
run() {
  node -e 'const p=process.argv[1],h=process.argv[2];process.stdout.write(JSON.stringify({tool_name:"Edit",tool_input:{file_path:p,new_string:h}}))' \
    "$NODE_TD/BACKLOG.md" "$HDR" | node "$HOOK" 2>&1
}

blocks() {
  local desc="$1"; local body="$2"; local out
  board "$body"; out="$(run)"
  if printf '%s' "$out" | grep -q '"permissionDecision":"deny"'; then PASS=$((PASS+1));
  else FAIL=$((FAIL+1)); FAILURES+=("EXPECTED-DENY: $desc (got: $(printf '%s' "$out" | head -c 160))"); fi
}
silent() {
  local desc="$1"; local body="$2"; local out
  board "$body"; out="$(run)"
  if [ "$out" = "{}" ]; then PASS=$((PASS+1));
  else FAIL=$((FAIL+1)); FAILURES+=("EXPECTED-SILENT: $desc (got: $(printf '%s' "$out" | head -c 200))"); fi
}

# --- D: the vocabulary is live on English board prose -----------------------
blocks "D1 follow-up card"        "the partition rebuild is left to a follow-up card"
blocks "D2 needs a separate card" "the remaining sweep needs a separate card"
blocks "D3 defers to a card"      "the migration defers to a card of its own"
blocks "D4 handed off to a card"  "the rest is handed off to a card"
blocks "D5 must be created"       "one more guard must be created before this closes"

# --- G: none of it fires on the same words in their other English sense -----
# G1 is the arm that fails if the qualifier is ever dropped from the `needs a card` alternation.
silent "G1 a payment card, not a board card" "the checkout page needs a card number before it can submit"
# G2 is the arm that fails if the lookahead is ever dropped from the hand-off alternation.
silent "G2 a card reader, not a board card"  "the terminal hands it off to a card reader on the counter"
silent "G3 no deferral admitted at all"      "the index was rebuilt in place and every partition now carries lastmod"

# --- controls for this fixture ----------------------------------------------
# C1: the same board with an `- owes-cards: (none)` line must be silent whatever the body says,
# because the vocabulary branch only runs when the field is ABSENT. Without this, D1-D5 could all
# be passing for the wrong reason.
printf '# BACKLOG\n\n%s\n- aliases: r-source-card\n- owes-cards: (none)\n- problem: x\n- fix: the partition rebuild is left to a follow-up card\n' \
  '### [REVIEW] R-source-card · P2' > "$TD/BACKLOG.md"
O="$(run)"
if [ "$O" = "{}" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILURES+=("C1 an explicit (none) must silence the vocabulary branch (got: $(printf '%s' "$O" | head -c 160))"); fi

# C2 must-RED harness control: prose in an owes-cards line that the WRITE introduces denies, which
# proves this fixture can see a denial at all. If C2 ever goes green, every D arm is uninformative.
board "nothing was deferred here"
O="$(node -e 'const p=process.argv[1];process.stdout.write(JSON.stringify({tool_name:"Edit",tool_input:{file_path:p,new_string:"- owes-cards: some prose about what is owed"}}))' \
  "$NODE_TD/BACKLOG.md" | node "$HOOK" 2>&1)"
if printf '%s' "$O" | grep -q '"permissionDecision":"deny"'; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILURES+=("C2 harness control: prose in owes-cards must deny (got: $(printf '%s' "$O" | head -c 160))"); fi

rm -rf "$TD"

name="$(basename "$0")"
TOTAL=$((PASS+FAIL))
if [ "$FAIL" -eq 0 ]; then
  echo "  $name: PASS ($PASS/$PASS) (arms run: $TOTAL)"
  exit 0
else
  echo "  $name: FAIL ($PASS pass, $FAIL fail) (arms run: $TOTAL)"
  for f in "${FAILURES[@]}"; do echo "    - $f"; done
  exit 1
fi

#!/usr/bin/env bash
# Fixture for hooks/block-deferral-without-landing.mjs after English-isation.
#
# This gate is a natural-language detector, so English-ising it is almost pure ADDITION in the
# firing direction: before the port it could fire on three ASCII phrases, after it there is a
# whole English vocabulary. A must-red suite would therefore prove nothing about the risk that
# actually matters here - that the gate now fires on ordinary English prose. So every detector
# class below is a PAIR: one D<n> arm that must BLOCK (the alternation is live), and one G<n>
# arm that must stay SILENT (the alternation is not eating legitimate sentences).
#
# G1 and G6 are the sharpest of the green arms: measured by reverting the one line that adds the
# word boundaries, those are the two that go red under substring containment - which is what the
# original language could afford and English cannot. G6 is the sharper of the two, and it was not
# the one predicted: `next round I` is a substring of `next round is`, so under containment every
# conditional sentence about a next round reads as a promise to act in it.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$(cd "$HERE/.." && pwd)/block-deferral-without-landing.mjs"

TD="$(mktemp -d)"
NODE_TD="$TD"
if command -v cygpath >/dev/null 2>&1; then NODE_TD="$(cygpath -m "$TD")"; fi
mkdir -p "$TD/board"
TX="$TD/transcript.jsonl"
NODE_TX="$NODE_TD/transcript.jsonl"

# An EMPTY board dir, on purpose: with no cards the landing check degrades to "a landing token is
# enough", which is the behaviour G2 and G3 assert. Pointing at a live board would make those two
# arms depend on whatever happens to be on it today.
export AAL_DEFERRAL_BOARD_DIR="$NODE_TD/board"
export AAL_GATE_DENIALS_OFF=1

PASS=0; FAIL=0; FAILURES=()

say() { printf '{"message":{"role":"assistant","content":[{"type":"text","text":"%s"}]}}\n' "$1" > "$TX"; }
run() { printf '{"transcript_path":"%s"}' "${1:-$NODE_TX}" | node "$HOOK" 2>&1; }

# must-BLOCK, and for the detector class we claim - not a neighbouring one.
blocks() {
  local desc="$1"; local text="$2"; local want="${3:-}"; local out
  say "$text"; out="$(run)"
  if ! printf '%s' "$out" | grep -q '"decision":"block"'; then
    FAIL=$((FAIL+1)); FAILURES+=("EXPECTED-BLOCK-BUT-SILENT: $desc (got: $(printf '%s' "$out" | head -c 160))")
  elif [ -n "$want" ] && ! printf '%s' "$out" | grep -qF "$want"; then
    FAIL=$((FAIL+1)); FAILURES+=("BLOCKED-BY-THE-WRONG-CLASS: $desc (want '$want' - got: $(printf '%s' "$out" | head -c 240))")
  else
    PASS=$((PASS+1))
  fi
}

# must-SILENT, asserted as EXACTLY `{}`. "no block" would also score a crashed gate as a pass.
silent() {
  local desc="$1"; local text="$2"; local out
  say "$text"; out="$(run)"
  if [ "$out" = "{}" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); FAILURES+=("EXPECTED-SILENT: $desc (got: $(printf '%s' "$out" | head -c 240))")
  fi
}

# --- D: every detector class fires on English ------------------------------
blocks "D1  DEFER phrase list"            "This one deserves a card of its own."           "deserves a card"
blocks "D2  subjectless next step"        "The next step is to backfill the partitions."       "subjectless debt"
blocks "D3  defer to the next round"      "Next round, run the whole sweep again."         "a status report IS a deferral"
blocks "D4  next noun is a pronoun"       "The next item is those."                        "pointed back at a pronoun"
blocks "D5  bare debt, nobody named"      "The suite is short by one fixture."             "no one named and no time named"
blocks "D6  status report of undone work" "The sweep is not done yet."                     "a status report IS a deferral"
blocks "D7  permission-seeking question"  "Do you want me to run it?"                      "dressed up as a question"
blocks "D8  immediacy without the act"    "I am about to push the branch."                 "on the spot"
blocks "D9  claiming instead of doing"    "That one is mine."                              "claiming it is not doing it"
blocks "D10 event-anchored deferral"      "After the merge I will run it."                 "event-anchored deferral"
blocks "D11 third-person debt"            "Lead still owes the walk."                      "third-person debt"
blocks "D12 self as the anchor"           "It is waiting for me to merge."                 "YOURSELF as the anchor"
blocks "D13 them as the anchor, lead-only act" "It is waiting for you to open a PR."       "THEM as the anchor"
# D14 is the arm for EXECUTOR_ANCHOR_RE, whose whole job is to CANCEL the landed-evidence
# exemption. Without it this sentence is skipped outright, and D12 would not have caught that,
# because D12 carries no landed evidence to be exempted by.
blocks "D14 landed evidence does not exempt an executor anchor" \
       "I already pushed the branch and it is waiting for me to merge."                    "YOURSELF as the anchor"

# --- G: none of it fires on legitimate English -----------------------------
# G1 fails the moment DEFER goes back to substring containment: `no rush` sits inside `no rushed`.
silent "G1  word boundary, not containment"  "There were no rushed conclusions in that sweep."
silent "G2  a deferral WITH an R-slug landing" "This one deserves a card, R-follow-up-card-slug."
silent "G3  a deferral WITH a batch landing"   "This one deserves a card, batch 3."
silent "G4  next step with no verb of ours"    "The next step is described in the plan."
silent "G5  next step, explicitly someone else's" "The next step is to dispatch, and that is handled by the reviewer."
silent "G6  next round inside a conditional"   "If the next round is red, the discriminator is the arm count."
silent "G7  undone work quoted as a reading"   "It reads like it is not done yet."
silent "G8  waiting on the user's own ruling"  "It is waiting for you to answer."
# G9 is the must-green for the one guard this port adds that the original does not have:
# OTHER_ACTOR_RE on the claim branch. `my job` survives its own negation as a substring.
silent "G9  a claim that is explicitly NOT ours" "That one is not my job, the reviewer owns it."
silent "G10 an event anchor with no future action" "After the merge the worktree is removed and the branch deleted."
# G11 guards the CONTENT of the immediacy list rather than the boundary mechanism: it stays green
# under containment too, because `I am about to` is not a substring of `I am about three`.
silent "G11 immediacy needs its preposition"   "I am about three commits behind."
silent "G14 landed evidence still exempts"     "We already pushed it and logged it."

# --- controls for the fixture itself ---------------------------------------
printf '' > "$TX"
O="$(run)"
if [ "$O" = "{}" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILURES+=("G12 empty transcript should be silent (got: $O)"); fi

O="$(run "$NODE_TD/there-is-no-such-file.jsonl")"
if [ "$O" = "{}" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILURES+=("G13 unreadable transcript should fail open (got: $O)"); fi

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

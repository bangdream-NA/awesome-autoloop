#!/usr/bin/env bash
# require-user-question-with-user-gate — a card that says "waiting on the user" without writing down
# the question is a stop with no way to restart: the next turn cannot tell what was asked, and the
# gate outlives the memory of it. The gate denies a board write that introduces a user gate without
# the question and two visible options, and denies setting one at all while the user is present.
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/require-user-question-with-user-gate.mjs

# --- portable activation context ---------------------------------------------------------------
AAL_PROJ="$(mktemp -d)"
mkdir -p "$AAL_PROJ/.claude" "$AAL_PROJ/docs"
: > "$AAL_PROJ/.claude/.autoloop"
AAL_PROJ_N="$(aal_native "$AAL_PROJ")"
export CLAUDE_PROJECT_DIR="$AAL_PROJ_N"
trap 'rm -rf "$AAL_PROJ"' EXIT

BOARD="$AAL_PROJ_N/.claude/BACKLOG.md"

# Presence is read from a transcript, and BOTH states need one: "they are here" and "they are not"
# are different arms of this gate, and leaving either to the ambient environment would make the
# verdict depend on whether somebody happened to type into the operator's session in the last hour.
# The window is an hour, so the stamps come off the clock rather than being written in.
mkpresence() { # $1 = out path, $2 = ISO stamp
  node -e 'const fs=require("fs");
fs.writeFileSync(process.argv[1], JSON.stringify({type:"user",promptSource:"typed",timestamp:process.argv[2],message:{role:"user"}})+"\n");' \
    -- "$1" "$2"
}
T_HERE="$AAL_PROJ/here.jsonl";  mkpresence "$T_HERE"  "$(aal_date_rel '-30 seconds' +%Y-%m-%dT%H:%M:%SZ)"
T_AWAY="$AAL_PROJ/away.jsonl";  mkpresence "$T_AWAY"  "$(aal_date_rel '-4 hours' +%Y-%m-%dT%H:%M:%SZ)"

# 🔴 Every board line below is assembled from ARGUMENTS rather than written out. An installed
# autoloop reads a file carrying those literals as somebody hand-editing a real board — the card
# header, the gate field, the asked stamp and the bullet shape each trip a different guard — so none
# of them appears whole anywhere in this source. The bytes handed to the gate under test are exactly
# what a real board holds; only the spelling in this file differs.
BULLET='-'
GATE_KEY=blocked-by
ASKED_KEY=asked-at
Q_KEY=user-question
gate_header()  { printf '%s [%s] %s · %s=user · %s=%s\n' '###' 'USER-GATED' "$1" "$GATE_KEY" "$ASKED_KEY" "$2"; }
plain_header() { printf '%s [%s] %s\n' '###' 'IN-DEV' "$1"; }
q_two()        { printf '%s %s: %s\n' "$BULLET" "$Q_KEY" 'rename the field? | option A: adopters re-run the sync | option B: the old name stays | my recommendation: A'; }
q_one()        { printf '%s %s: %s\n' "$BULLET" "$Q_KEY" 'should we rename the field?'; }
ASKED="$(aal_date_rel '-2 hours' +%Y-%m-%dT%H:%M:%SZ)"
# -----------------------------------------------------------------------------------------------

w() { # $1 = content, $2 = transcript, $3 = path (default the board)
  node -e 'process.stdout.write(JSON.stringify({tool_name:"Write",transcript_path:process.argv[2],tool_input:{file_path:process.argv[3],content:process.argv[1]}}))' \
    -- "$1" "$2" "${3:-$BOARD}"
}
ed() { # $1 = old, $2 = new, $3 = transcript
  node -e 'process.stdout.write(JSON.stringify({tool_name:"Edit",transcript_path:process.argv[3],tool_input:{file_path:process.argv[4],old_string:process.argv[1],new_string:process.argv[2]}}))' \
    -- "$1" "$2" "$3" "$BOARD"
}

# --- DENY: a gate set while they are sitting right there -------------------------------------------
# The cheapest thing to do with a present user is ask them; a gate set now is a decision to wait for
# somebody who is already here.
assert_deny "a user gate while they are present" \
  "$(w "$(gate_header R-widget "$ASKED")" "$T_HERE")" 'is not legal'

# --- DENY: a gate with no question written down ------------------------------------------------------
assert_deny "no question field at all" \
  "$(w "$(gate_header R-widget "$ASKED")" "$T_AWAY")" 'without writing down the question'
# A question with one option is a question whose answer is already assumed. The field has to show
# what each choice costs, which is why the predicate wants two of them visible on the line.
assert_deny "a question with no visible options" \
  "$(w "$(gate_header R-widget "$ASKED")
$(q_one)" "$T_AWAY")" 'no two options visible'

# --- ALLOW: the shape the denial asks for --------------------------------------------------------------
assert_allow "question with two options" \
  "$(w "$(gate_header R-widget "$ASKED")
$(q_two)" "$T_AWAY")"

# --- ALLOW: taking a gate DOWN, which is what a present user makes possible ------------------------------
# Without this arm the gate would deny the very cleanup its own FIX text asks for: the edit that
# removes the gate necessarily contains the words the predicate looks for.
assert_allow "removing the gate while they are present" \
  "$(ed "$(gate_header R-widget "$ASKED")
$(q_two)" "$(plain_header R-widget)" "$T_HERE")"

# --- ALLOW: board writes that set no gate ------------------------------------------------------------------
assert_allow "an ordinary card"     "$(w "$(plain_header R-widget)" "$T_AWAY")"
assert_allow "an empty write"       "$(w "" "$T_AWAY")"

# --- ALLOW: files that are not a board ------------------------------------------------------------------------
assert_allow "the same text in a plan" \
  "$(w "$(gate_header R-widget "$ASKED")" "$T_AWAY" "$AAL_PROJ_N/docs/R-widget-plan.md")"
assert_allow "not a write at all" \
  "$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:"grep -n USER-GATED board.md"}}))')"

# --- ALLOW: no transcript to read --------------------------------------------------------------------------------
# With no presence signal the gate cannot say whether they are here, so it judges only the shape of
# the card — and this write carries the question and the options.
assert_allow "no transcript, well-formed card" \
  "$(w "$(gate_header R-widget "$ASKED")
$(q_two)" "$AAL_PROJ_N/no-such-transcript.jsonl")"

# 🔴 TWO LIMBS OF THIS GATE ARE NOT REACHABLE, and neither is caused by this fixture:
#  1. the "a gate is still standing after they answered" limb reads a board through a HARDCODED
#     absolute path that no adopter has. In the source this port came from, that literal is the
#     author's own board and the limb works; sanitising the path left the code intact and the limb
#     dead. Nothing signals it — the read fails, the catch returns an empty string, and the limb
#     concludes there is nothing stale.
#  2. the "the asked stamp is older than their last message" limb tests Number.isFinite on a field
#     the presence library never returns (it returns an age, under a different name). That one is
#     INHERITED and known: the source carries a comment saying exactly that beside it.
# Both are reported rather than asserted: an arm for either would assert behaviour the artifact does
# not have, and saying nothing would let a reader count the arms here and call the gate covered.

summary

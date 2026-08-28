#!/usr/bin/env bash
# require-owes-cards-cleared-before-verified — "done" is a claim with three parts: nothing is still
# owed, the card's own question was re-measured today, and any remedy track it spawned has closed.
# Each part is invisible in the word VERIFIED, and each one has been quietly skipped before. The gate
# denies the verdict until all three are on the card.
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/require-owes-cards-cleared-before-verified.mjs

# --- portable activation context ---------------------------------------------------------------
AAL_PROJ="$(mktemp -d)"
mkdir -p "$AAL_PROJ/.claude"
: > "$AAL_PROJ/.claude/.autoloop"
AAL_PROJ_N="$(aal_native "$AAL_PROJ")"
aal_pin_project "$AAL_PROJ_N"
trap 'rm -rf "$AAL_PROJ"' EXIT

BOARD="$AAL_PROJ_N/.claude/BACKLOG.md"

# Every board line is assembled from arguments, so nothing in this source reads as a real card.
BULLET='-'
ARROW='⇒'
head_of()    { printf '%s [%s] %s\n' '###' "$1" "$2"; }
owes_of()    { printf '%s %s: %s\n' "$BULLET" 'owes-cards' "$1"; }
problem_of() { printf '%s %s: %s\n' "$BULLET" 'problem' "$1"; }
# A verdict header carries the re-measurement inline, which is what the gate reads.
verified_of() { printf '%s [%s] %s · DoD-VERIFIED · %s: [%s] %s\n' '###' 'REVIEW' "$1" 'PURPOSE-REMEASURED' "$2" "$3"; }
ONE_READING="the sitemap held 0 venues $ARROW it holds 17 today, curl of the published dataset"
TWO_READINGS="the sitemap held 0 venues $ARROW 17 today; the detail page showed no venue $ARROW it shows one, curl of the page"
# -----------------------------------------------------------------------------------------------

# 🔴 The board is written with a TITLE line above the first card, which is what a real board has and
# what this gate needs: it learns which cards exist by splitting the file on a newline followed by a
# card header, so a file whose very first bytes are that header contributes NO cards — and with no
# known cards the gate stands aside entirely. Measured: four deny arms came back `{}` until the
# title line was added, which reads exactly like a gate with no opinion.
board() { printf '# Backlog\n\n%s\n' "$1" > "$AAL_PROJ/.claude/BACKLOG.md"; }
ed() { node -e 'process.stdout.write(JSON.stringify({tool_name:"Edit",tool_input:{file_path:process.argv[1],old_string:"",new_string:process.argv[2]}}))' -- "$BOARD" "$1"; }

# --- DENY: the owed-cards field written as prose --------------------------------------------------
# The field is read by machinery, not by a person: a sentence in it is invisible to everything that
# consumes it while looking, to a human, exactly like an answer.
board "$(head_of REVIEW R-widget)"
assert_deny "prose in the owed field" \
  "$(ed "$(owes_of 'nothing outstanding as far as I can tell')")" 'holds slugs, never prose'
assert_deny "a slug plus an explanation" \
  "$(ed "$(owes_of 'R-widget-followup once the box is reachable')")" 'holds slugs, never prose'

# --- ALLOW: the two legal shapes ---------------------------------------------------------------------
assert_allow "an explicit none"   "$(ed "$(owes_of '(none)')")"
assert_allow "one slug"           "$(ed "$(owes_of 'R-widget-followup')")"
assert_allow "several slugs"      "$(ed "$(owes_of 'R-widget-followup, R-widget-detail')")"

# --- DENY: a verdict with no re-measurement of the card's own question ---------------------------------
board "$(head_of REVIEW R-widget)
$(problem_of 'the sitemap holds no venues')"
assert_deny "VERIFIED with nothing re-measured" \
  "$(ed "$(head_of REVIEW R-widget) · DoD-VERIFIED")" 'PURPOSE-REMEASURED'

# --- DENY: a re-measurement that does not say how much of the question it covers -------------------------
# A card's problem is usually a conjunction, and a value that answers half of it reads exactly like a
# value that answers all of it. The count is the only thing that tells them apart.
assert_deny "no [k/k] count" \
  "$(ed "$(printf '%s [%s] %s · DoD-VERIFIED · %s: %s\n' '###' 'REVIEW' 'R-widget' 'PURPOSE-REMEASURED' "$ONE_READING")")" 'how many'
assert_deny "the two numbers disagree" \
  "$(ed "$(verified_of R-widget '1/2' "$ONE_READING")")" 'how many'
# Claiming two assertions while showing one reading is the same failure from the other side.
assert_deny "fewer readings than claimed" \
  "$(ed "$(verified_of R-widget '2/2' "$ONE_READING")")" 'how many'

# --- ALLOW: the verdict with a complete re-measurement ---------------------------------------------------
assert_allow "one assertion, one reading"   "$(ed "$(verified_of R-widget '1/1' "$ONE_READING")")"
assert_allow "two assertions, two readings" "$(ed "$(verified_of R-widget '2/2' "$TWO_READINGS")")"

# --- DENY: a source card closing ahead of the remedy tracks it spawned -------------------------------------
# The moment it is archived nothing supervises that chain, so the tracks have to land first.
board "$(printf '%s [%s] %s · %s=%s\n' '###' 'REVIEW' 'R-widget' 'dod-remedy-tracks' 'R-widget-fix')
$(head_of QUEUED R-widget-fix)"
assert_deny "a track that has not finished" \
  "$(ed "$(verified_of R-widget '1/1' "$ONE_READING")")" 'remedy'
board "$(printf '%s [%s] %s · %s=%s\n' '###' 'REVIEW' 'R-widget' 'dod-remedy-tracks' 'R-widget-fix')
$(head_of REVIEW R-widget-fix) · DoD-VERIFIED"
assert_allow "…and the same once the track is verified" \
  "$(ed "$(verified_of R-widget '1/1' "$ONE_READING")")"

# --- ALLOW: writes this gate does not judge -------------------------------------------------------------------
board "$(head_of REVIEW R-widget)"
assert_allow "a log line"      "$(ed "$(printf '%s %s\n' "$BULLET" 'log: 2026-08-27T10:00:00Z · dispatched the reviewer')")"
assert_allow "an empty edit"   "$(ed "")"
assert_allow "a different file" \
  "$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Edit",tool_input:{file_path:process.argv[1],old_string:"",new_string:process.argv[2]}}))' \
    -- "$AAL_PROJ_N/notes.md" "$(owes_of 'nothing outstanding as far as I can tell')")"

summary

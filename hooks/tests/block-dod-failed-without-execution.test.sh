#!/usr/bin/env bash
# block-dod-failed-without-execution — writing a failure stamp is a claim that the thing was run and
# came back wrong. Two states get mislabelled that way: a measurement with no reading beside it, and
# a measurement taken before the ship action ever handed the change over. Neither is a failure; both
# stop the card in a way nobody revisits. The gate denies a NEW failure stamp in either state.
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/block-dod-failed-without-execution.mjs

# --- portable activation context ---------------------------------------------------------------
AAL_PROJ="$(mktemp -d)"
mkdir -p "$AAL_PROJ/.claude" "$AAL_PROJ/docs/product-specs"
: > "$AAL_PROJ/.claude/.autoloop"
AAL_PROJ_N="$(aal_native "$AAL_PROJ")"
aal_pin_project "$AAL_PROJ_N"
trap 'rm -rf "$AAL_PROJ"' EXIT

BOARD="$AAL_PROJ_N/.claude/BACKLOG.md"

# Board lines are assembled from arguments: an installed autoloop reads a file carrying the literals
# as somebody hand-editing a real board, so none of them appears whole in this source. The bytes the
# gate receives are what a real card holds.
FAILED_KEY=dod-failed-at
SHIP_KEY=ship
BULLET='-'
STAMP="$(aal_date_rel '-1 hour' +%Y-%m-%dT%H:%M:%SZ)"
OLDSTAMP="$(aal_date_rel '-3 days' +%Y-%m-%dT%H:%M:%SZ)"
card()      { printf '%s [%s] %s · %s=%s\n' '###' 'BLOCKED' "$1" "$FAILED_KEY" "$2"; }
readings()  { printf '%s %s\n' "$BULLET" 'observed=0 · expected=17 · the sitemap held nothing'; }
shipline()  { printf '%s %s: %s · owner=%s · ran=%s\n' "$BULLET" "$SHIP_KEY" 'republish the dataset' "$1" "$2"; }
waveref()   { printf '%s %s\n' "$BULLET" 'spec: docs/product-specs/R-widget-plan.md'; }
# -----------------------------------------------------------------------------------------------

w() { node -e 'process.stdout.write(JSON.stringify({tool_name:"Write",tool_input:{file_path:process.argv[1],content:process.argv[2]}}))' -- "$1" "$2"; }

# --- DENY: a failure stamp with no reading beside it ------------------------------------------------
# "It failed" without a pair of numbers cannot be re-checked by anyone, including its author an hour
# later: there is nothing to re-measure against.
assert_deny "no observed= or expected=" \
  "$(w "$BOARD" "$(card R-widget "$STAMP")")" 'BLOCKED'
assert_deny "only one of the two readings" \
  "$(w "$BOARD" "$(card R-widget "$STAMP")
$(printf '%s %s\n' '-' 'observed=0 · the sitemap held nothing')")" 'BLOCKED'

# --- DENY: readings taken before the ship action handed anything over ---------------------------------
assert_deny "no ship line at all" \
  "$(w "$BOARD" "$(card R-widget "$STAMP")
$(readings)")" 'not a failure, it is unfinished'
assert_deny "a ship line that never ran" \
  "$(w "$BOARD" "$(card R-widget "$STAMP")
$(readings)
$(shipline lead pending)")" 'not a failure, it is unfinished'

# --- ALLOW: a real failure — measured, and measured AFTER the ship ---------------------------------------
assert_allow "readings plus a discharged ship" \
  "$(w "$BOARD" "$(card R-widget "$STAMP")
$(readings)
$(shipline lead "$OLDSTAMP")")"
# A ship action that genuinely has nothing to run says so in the same field, rather than leaving the
# reader to guess whether it was forgotten.
# 🔴 The reason must carry NO SPACE after the marker. `ran=` is read up to the first whitespace, so
# `ran=N-A: the change is test-only` yields the token `N-A:` alone, which fails the "marker plus a
# reason" test and is denied — while `ran=N-A:test-only` passes. Measured both ways; the natural
# spelling is the one that is refused, and the denial talks about the ship action rather than about
# the spacing, so the author is sent to run something instead of to close up a gap.
assert_allow "an explicit not-applicable ship" \
  "$(w "$BOARD" "$(card R-widget "$STAMP")
$(readings)
$(shipline lead 'N-A:test-only-change-reaches-nothing-outside-the-repo')")"
assert_deny "…the same reason with a space after the marker" \
  "$(w "$BOARD" "$(card R-widget "$STAMP")
$(readings)
$(shipline lead 'N-A: test only')")" 'not a failure, it is unfinished'

# --- ALLOW: an anchor that was ALREADY on the board ---------------------------------------------------------
# The gate judges what this write INTRODUCES. Without that, every later edit to a card carrying an old
# failure would be denied again, and the only way to touch the board would be to delete the evidence.
printf '%s\n' "$(card R-widget "$OLDSTAMP")" > "$AAL_PROJ/.claude/BACKLOG.md"
assert_allow "re-writing an existing stamp" \
  "$(w "$BOARD" "$(card R-widget "$OLDSTAMP")
$(printf '%s %s\n' '-' 'log: still waiting on the box')")"
: > "$AAL_PROJ/.claude/BACKLOG.md"

# --- ALLOW: boards with no failure stamp, and files that are not boards -----------------------------------------
assert_allow "an ordinary card"    "$(w "$BOARD" "$(printf '%s [%s] %s\n' '###' 'IN-DEV' 'R-widget')")"
assert_allow "an empty write"      "$(w "$BOARD" "")"
assert_allow "the same text in a plan" \
  "$(w "$AAL_PROJ_N/docs/product-specs/R-widget-plan.md" "$(card R-widget "$STAMP")")"
assert_allow "not a write at all" \
  "$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:"grep -n dod-failed board.md"}}))')"

# --- the denial quotes the wave's own ship action when the spec has one -------------------------------------------
# Naming the action beats naming the omission: the reader is told which line of which document to go
# and satisfy. This arm is what keeps that lookup from silently dropping out.
printf '## §S Ship action\n\nRepublish the dataset after the merge · owner=lead\n' > "$AAL_PROJ/docs/product-specs/R-widget-plan.md"
out="$(w "$BOARD" "$(card R-widget "$STAMP")
$(readings)
$(waveref)
$(shipline lead pending)" | node "$HOOK" 2>&1)"
if printf '%s' "$out" | grep -q 'Republish the dataset after the merge'; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  FAILURES+=("SHIP-DOC: the denial does not quote the wave's §S line (got: $(printf '%s' "$out" | head -c 160))")
fi

summary

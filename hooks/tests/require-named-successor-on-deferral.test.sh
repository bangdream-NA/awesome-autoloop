#!/usr/bin/env bash
# require-named-successor-on-deferral — "left to a follow-up wave" is only a plan if the follow-up
# has a name. Without one the sentence reads as a decision while nothing anywhere owns the work.
# The gate denies a deferral phrase on a board file unless an existing card slug sits beside it, or
# a PR number sits AFTER it.
source "$(dirname "$0")/_lib.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$HERE/../require-named-successor-on-deferral.mjs"

# --- portable activation context ---------------------------------------------------------------
AAL_PROJ="$(mktemp -d)"
mkdir -p "$AAL_PROJ/.claude" "$AAL_PROJ/docs"
: > "$AAL_PROJ/.claude/.autoloop"
AAL_PROJ_N="$(aal_native "$AAL_PROJ")"
export CLAUDE_PROJECT_DIR="$AAL_PROJ_N"
trap 'rm -rf "$AAL_PROJ"' EXIT

BOARD="$AAL_PROJ_N/.claude/BACKLOG.md"
# The gate reads the SIBLING board files to learn which slugs exist, so a named successor is only
# accepted when the card is really there — that is the difference between naming a successor and
# inventing one, and it is why this fixture writes a board rather than passing content alone.
# The header marker is a printf ARGUMENT rather than part of the format: an autoloop installation
# reads any file whose lines begin with a card header as somebody editing a board, this fixture
# included, so the literal shape cannot appear at the start of a line in the source.
card_header() { printf '%s [%s] %s\n' '###' "$1" "$2"; }
{ card_header QUEUED R-widget-detail; card_header QUEUED R-widget-followup; } > "$AAL_PROJ/.claude/BACKLOG.md"
# -----------------------------------------------------------------------------------------------

w() { node -e 'process.stdout.write(JSON.stringify({tool_name:"Write",tool_input:{file_path:process.argv[1],content:process.argv[2]}}))' -- "$1" "$2"; }
ed() { node -e 'process.stdout.write(JSON.stringify({tool_name:"Edit",tool_input:{file_path:process.argv[1],old_string:"x",new_string:process.argv[2]}}))' -- "$1" "$2"; }

# --- DENY: a deferral with nobody named -----------------------------------------------------------
assert_deny "the next cutover window" \
  "$(w "$BOARD" "installing the new build is the next cutover window.")" 'names nobody to take it'
assert_deny "a separate wave" \
  "$(w "$BOARD" "Rewriting the call sites to use the wrappers is a separate wave.")" 'names nobody to take it'
assert_deny "a follow-up card" \
  "$(w "$BOARD" "The empty state needs its own copy; that is a follow-up card.")" 'names nobody to take it'
assert_deny "left to another wave" \
  "$(w "$BOARD" "The migration replay is left to another wave.")" 'names nobody to take it'
assert_deny "an Edit, not only a Write" \
  "$(ed "$BOARD" "installing the new build is the next cutover window.")" 'names nobody to take it'
# A slug that is on no board is an invented successor: it reads as a name and owns nothing. Without
# this arm, accepting any `R-…`-shaped string would look exactly as green.
assert_deny "a slug that is not on the board" \
  "$(w "$BOARD" "installing the new build is the next cutover window, handed to R-no-such-card-at-all.")" 'names nobody to take it'
# 🔴 The trap this gate exists for: a PR number BEFORE the phrase describes what is being EXCLUDED,
# not who picks it up. Reading it as a landing turns the exact sentence that lost the work into a pass.
assert_deny "a PR number BEFORE the deferral" \
  "$(w "$BOARD" "this card does not include the wrappers #1193 added; installing the build is the next cutover window.")" 'names nobody to take it'

# --- ALLOW: the two landings the denial names -------------------------------------------------------
assert_allow "an existing slug beside the phrase" \
  "$(w "$BOARD" "installing the allowlist on the box is a follow-up card, R-widget-followup.")"
assert_allow "a PR number AFTER the phrase" \
  "$(w "$BOARD" "installing the new build is the next cutover window, see #1229.")"

# --- ALLOW: sentences that are not deferrals ----------------------------------------------------------
assert_allow "a completed statement"  "$(w "$BOARD" "Installed the new build and read the version back from the box.")"
assert_allow "an ordinary card body"  "$(w "$BOARD" "$(card_header IN-DEV R-widget-detail)")"

# --- ALLOW: files that are not a board ------------------------------------------------------------------
# Deferral language belongs in prose documents; only a board row is a claim about who owns work.
assert_allow "the same sentence in a plan" \
  "$(w "$AAL_PROJ_N/docs/R-widget-plan.md" "Rewriting the call sites is a separate wave.")"
assert_allow "not a write at all" \
  "$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:"echo that is a separate wave"}}))')"

# --- the gate ships its own predicate self-test; run it and read its own counters ---------------------
# The arm count is DERIVED from the output, so adding an arm there cannot silently shrink this check,
# while a failing arm or an empty run reddens here.
selftest_out="$(node "$HOOK" --self-test 2>&1)"; selftest_rc=$?
armtotal="$(printf '%s\n' "$selftest_out" | grep -cE '^(ok  |FAIL) ')"
armfail="$(printf '%s\n' "$selftest_out" | grep -cE '^FAIL ')"
if [ "$selftest_rc" -eq 0 ] && [ "$armtotal" -ge 1 ] && [ "$armfail" -eq 0 ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  FAILURES+=("SELF-TEST: rc=$selftest_rc arms=$armtotal failing=$armfail (tail: $(printf '%s' "$selftest_out" | tail -c 120))")
fi

summary

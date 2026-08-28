#!/usr/bin/env bash
# block-dod-verified-with-self-declared-gap — a Definition of Done has two honest outcomes, and both
# of these are attempts at a third. One writes the verdict and then admits in the next clause that
# nothing was actually driven; the other keeps the verdict and shrinks what it covers. The second is
# the harder one, because it admits no gap at all — it reads as prudence.
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/block-dod-verified-with-self-declared-gap.mjs

# --- portable activation context ---------------------------------------------------------------
AAL_PROJ="$(mktemp -d)"
mkdir -p "$AAL_PROJ/.claude"
: > "$AAL_PROJ/.claude/.autoloop"
AAL_PROJ_N="$(aal_native "$AAL_PROJ")"
export CLAUDE_PROJECT_DIR="$AAL_PROJ_N"
trap 'rm -rf "$AAL_PROJ"' EXIT

BOARD="$AAL_PROJ_N/.claude/BACKLOG.md"
BULLET='-'
# Assembled from arguments so no line of this source reads as a card to an installed autoloop.
verdict() { printf '%s [%s] %s · DoD-VERIFIED%s\n' '###' 'REVIEW' 'R-widget' "$1"; }
note()    { printf '%s %s\n' "$BULLET" "$1"; }
# -----------------------------------------------------------------------------------------------

ed() { node -e 'process.stdout.write(JSON.stringify({tool_name:"Edit",tool_input:{file_path:process.argv[1],old_string:"x",new_string:process.argv[2]}}))' -- "$1" "$2"; }

# --- DENY: the verdict, with the gap confessed beside it -----------------------------------------------
assert_deny "never actually ran it" \
  "$(ed "$BOARD" "$(verdict '')
$(note 'the workflow was never actually triggered, so the run is inferred from the config')")" 'BLOCKED'
assert_deny "could not drive it" \
  "$(ed "$BOARD" "$(verdict '')
$(note 'I could not exercise the admin path first-hand — no account exists for it')")" 'BLOCKED'
assert_deny "not end-to-end verified" \
  "$(ed "$BOARD" "$(verdict '')
$(note 'the pieces are in place, though this is not end-to-end verified')")" 'BLOCKED'

# --- DENY: the verdict with its scope quietly narrowed ----------------------------------------------------
# The layer above hunts for confessions; this one has none to find. The claim simply gets smaller,
# and once it lands the card reads as settled to everything downstream.
assert_deny "a scope in parentheses" \
  "$(ed "$BOARD" "$(verdict ' (scope = the delivered phase 1a artifact; the other three gaps go to a follow-up)')")" 'SCOPE-NARROWING'
assert_deny "scoped to" \
  "$(ed "$BOARD" "$(verdict ' [scoped to the search page only]')")" 'SCOPE-NARROWING'
assert_deny "partial" \
  "$(ed "$BOARD" "$(verdict ': partially — the detail page still has no venue')")" 'SCOPE-NARROWING'
assert_deny "only phase one" \
  "$(ed "$BOARD" "$(verdict ' (only phase 1 of the migration)')")" 'SCOPE-NARROWING'

# --- ALLOW: the two honest outcomes -----------------------------------------------------------------------
assert_allow "a bare verdict" "$(ed "$BOARD" "$(verdict '')")"
assert_allow "a verdict with evidence beside it" \
  "$(ed "$BOARD" "$(verdict '')
$(note 'curled the published dataset and read back 17 venues, screenshot in the walk file')")"
# A failure is not this gate's business at all: saying it broke is the outcome it is pushing people
# towards, so it has to pass cleanly even when the same sentence describes the gap.
assert_allow "an honest failure" \
  "$(ed "$BOARD" "$(printf '%s [%s] %s · DoD-FAILED · %s\n' '###' 'BLOCKED' 'R-widget' 'dod-failed-at=2026-08-26T09:00:00Z')
$(note 'I could not exercise the admin path first-hand — no account exists for it')")"

# --- ALLOW: the word scope where it narrows nothing -----------------------------------------------------------
# The predicate wants the qualifier ATTACHED to the verdict. A card that discusses scope elsewhere is
# an ordinary card, and denying it would make the word unusable on any card that ends up verified.
assert_allow "scope discussed elsewhere on the card" \
  "$(ed "$BOARD" "$(verdict '')
$(note 'the scope section of the plan lists three pages, all three walked')")"
assert_allow "an empty edit"  "$(ed "$BOARD" "")"
assert_allow "a card with no verdict" \
  "$(ed "$BOARD" "$(printf '%s [%s] %s\n' '###' 'IN-DEV' 'R-widget')")"

# --- ALLOW: files and tools this gate does not judge --------------------------------------------------------------
assert_allow "a plan document" \
  "$(ed "$AAL_PROJ_N/docs/product-specs/R-widget-plan.md" "$(verdict ' (scope = phase 1a only)')")"
assert_allow "not an edit at all" \
  "$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:"grep -n DoD-VERIFIED board.md"}}))')"

summary

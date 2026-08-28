#!/usr/bin/env bash
# backlog-slug-matches-wave — the review ledger keys verdicts by WAVE name while the board keys cards
# by SLUG. When the two differ, one gate resolves the verdict through the aliases and allows, another
# resolves it through the slug alone and refuses — one concept, two mechanisms, opposite answers, and
# each looks right on its own. The gate denies a card whose slug and branch name disagree.
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/backlog-slug-matches-wave.mjs

# --- portable activation context ---------------------------------------------------------------
AAL_PROJ="$(mktemp -d)"
mkdir -p "$AAL_PROJ/.claude"
: > "$AAL_PROJ/.claude/.autoloop"
AAL_PROJ_N="$(aal_native "$AAL_PROJ")"
export CLAUDE_PROJECT_DIR="$AAL_PROJ_N"
trap 'rm -rf "$AAL_PROJ"' EXIT

BOARD="$AAL_PROJ_N/.claude/BACKLOG.md"
# Assembled from arguments so no line of this source reads as a real card.
BULLET='-'
card_with_branch() { # $1 = slug, $2 = branch
  printf '%s [%s] %s\n%s %s: feat/%s\n' '###' 'IN-DEV' "$1" "$BULLET" 'aliases' "$2"
}
# -----------------------------------------------------------------------------------------------

w() { node -e 'process.stdout.write(JSON.stringify({tool_name:"Write",tool_input:{file_path:process.argv[1],content:process.argv[2]}}))' -- "$1" "$2"; }

# --- DENY: the slug and the branch name are different waves ------------------------------------------
assert_deny "slug and branch disagree" \
  "$(w "$BOARD" "$(card_with_branch R-venue-empty r-widget-detail)")" 'does not match the wave name'
# The denial has to NAME the wave to rename to, or the reader is left to work out which of the two
# spellings is the authoritative one — and the answer is never the card.
assert_deny "…and it names the wave to use" \
  "$(w "$BOARD" "$(card_with_branch R-venue-empty r-widget-detail)")" 'R-widget-detail'

# --- ALLOW: the two agree ------------------------------------------------------------------------------
assert_allow "an exact match" \
  "$(w "$BOARD" "$(card_with_branch R-widget-detail r-widget-detail)")"
# A trailing round number on the branch is not a different wave: `feat/r-widget-detail2` is the same
# work, and denying it would send somebody renaming a card to match a typo.
assert_allow "a branch with a round suffix" \
  "$(w "$BOARD" "$(card_with_branch R-widget-detail r-widget-detail2)")"

# --- ALLOW: nothing to compare ---------------------------------------------------------------------------
# Each of these is a separate reason the comparison cannot be made, and each needs its own arm: a card
# with no branch, a card with no slug, and a branch that is not a wave branch at all.
assert_allow "no aliases line" \
  "$(w "$BOARD" "$(printf '%s [%s] %s\n' '###' 'IN-DEV' 'R-widget-detail')")"
assert_allow "a header with no slug" \
  "$(w "$BOARD" "$(printf '%s [%s] %s\n%s %s: feat/r-widget-detail\n' '###' 'IN-DEV' 'something else' "$BULLET" 'aliases')")"
assert_allow "an aliases line naming no branch" \
  "$(w "$BOARD" "$(printf '%s [%s] %s\n%s %s: the venue card, the empty-state card\n' '###' 'IN-DEV' 'R-widget-detail' "$BULLET" 'aliases')")"
assert_allow "an empty write" "$(w "$BOARD" "")"

# --- ALLOW: files this gate does not read -----------------------------------------------------------------
# The archive and the detail ledger hold the same shapes and are not where a live mismatch can hurt:
# both are read by people, not by the resolvers that disagree.
assert_allow "an archive file" \
  "$(w "$AAL_PROJ_N/.claude/BACKLOG-archive-01.md" "$(card_with_branch R-venue-empty r-widget-detail)")"
assert_allow "the detail ledger" \
  "$(w "$AAL_PROJ_N/.claude/BACKLOG-detail-2026-08.md" "$(card_with_branch R-venue-empty r-widget-detail)")"
assert_allow "not a board at all" \
  "$(w "$AAL_PROJ_N/notes.md" "$(card_with_branch R-venue-empty r-widget-detail)")"

summary

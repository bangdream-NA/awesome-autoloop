#!/usr/bin/env bash
# backlog-gate-vocab — a card that says it is blocked has to say on WHAT, in a vocabulary something
# can act on. The retired spellings all failed the same way: they named our own work, so no external
# event could ever clear them, and the card sat there looking like a decision. This fixture covers the
# token vocabulary and its neighbouring checks; the widening fixture beside it covers the executor
# predicates.
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/backlog-gate-vocab.mjs

# --- portable activation context ---------------------------------------------------------------
AAL_PROJ="$(mktemp -d)"
mkdir -p "$AAL_PROJ/.claude"
: > "$AAL_PROJ/.claude/.autoloop"
AAL_PROJ_N="$(aal_native "$AAL_PROJ")"
export CLAUDE_PROJECT_DIR="$AAL_PROJ_N"
trap 'rm -rf "$AAL_PROJ"' EXIT

BOARD="$AAL_PROJ_N/.claude/BACKLOG.md"
ASKED="$(aal_date_rel '-1 hour' +%Y-%m-%dT%H:%M:%SZ)"
GATE_KEY=blocked-by
# Assembled from arguments, so nothing in this source reads as a card to an installation.
gated() { printf '%s [%s] %s · %s=%s%s\n' '###' "${4:-BLOCKED}" "$1" "$GATE_KEY" "$2" "${3:-}"; }
# -----------------------------------------------------------------------------------------------

w() { node -e 'process.stdout.write(JSON.stringify({tool_name:"Write",tool_input:{file_path:process.argv[1],content:process.argv[2]}}))' -- "$1" "$2"; }

# --- DENY: tokens outside the vocabulary -------------------------------------------------------------
# Each of these names OUR OWN work, which is why they were retired: nothing outside the session can
# ever clear them, so the card stops moving and nothing ever notices.
assert_deny "a bare PR number"   "$(w "$BOARD" "$(gated R-widget 'pr#1229')")"      'BLOCKED'
assert_deny "a date"             "$(w "$BOARD" "$(gated R-widget 'until:2026-09-01')")" 'BLOCKED'
assert_deny "server-op"          "$(w "$BOARD" "$(gated R-widget 'server-op')")"    'BLOCKED'
assert_deny "an overlap"         "$(w "$BOARD" "$(gated R-widget 'overlap:pr#1229')")" 'BLOCKED'

# --- ALLOW: the three tokens that name an external event ------------------------------------------------
assert_allow "merge order on a PR"    "$(w "$BOARD" "$(gated R-widget 'merge-order:pr#1229')")"
assert_allow "merge order on a wave"  "$(w "$BOARD" "$(gated R-widget 'merge-order:wave:R-other-thing')")"
assert_allow "the user, with a stamp" "$(w "$BOARD" "$(gated R-widget user " · asked-at=$ASKED" USER-GATED)")"

# --- DENY: waiting on the user without ever having asked -------------------------------------------------
# The stamp is the difference between "they have the question" and "I decided to wait". Only one of
# those ever ends.
assert_deny "user with no asked-at" "$(w "$BOARD" "$(gated R-widget user '' USER-GATED)")" 'BLOCKED'

# --- DENY: a card that is both gated and finished ----------------------------------------------------------
# Two states that cannot both be true. Left alone, whichever one a reader notices first wins.
assert_deny "gated and verified at once" \
  "$(w "$BOARD" "$(gated R-widget 'merge-order:pr#1229' ' · DoD-VERIFIED')")" 'BLOCKED'

# --- DENY: a gate declared with nothing in it ----------------------------------------------------------------
# The status matters here: an empty declaration is only an offence on a card that is still OPEN
# (queued, in development, in review). On a card already badged as blocked there is nothing left to
# stall, which is why the same line passes below.
assert_deny "an empty gate on an open card" \
  "$(w "$BOARD" "$(printf '%s [%s] %s · [gate = ]\n' '###' 'QUEUED' 'R-widget')")" 'BLOCKED'
assert_allow "…the same line on a blocked card" \
  "$(w "$BOARD" "$(printf '%s [%s] %s · [gate = ]\n' '###' 'BLOCKED' 'R-widget')")"

# --- ALLOW: cards that declare no gate at all -------------------------------------------------------------------
assert_allow "an ordinary card"  "$(w "$BOARD" "$(printf '%s [%s] %s\n' '###' 'IN-DEV' 'R-widget')")"
assert_allow "a verified card"   "$(w "$BOARD" "$(printf '%s [%s] %s · DoD-VERIFIED\n' '###' 'REVIEW' 'R-widget')")"
assert_allow "an empty write"    "$(w "$BOARD" "")"
# A body line is not a header: the vocabulary is enforced on the card HEADER, which is what the
# machinery reads, and prose below it describes rather than declares.
assert_allow "the same words in a body line" \
  "$(w "$BOARD" "$(printf '%s [%s] %s\n%s\n' '###' 'IN-DEV' 'R-widget' '- log: it was blocked-by=server-op until yesterday')")"

# --- ALLOW: files this gate does not judge -----------------------------------------------------------------------
assert_allow "a plan document" \
  "$(w "$AAL_PROJ_N/docs/product-specs/R-widget-plan.md" "$(gated R-widget 'server-op')")"
assert_allow "not a write at all" \
  "$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:"grep -n blocked-by board.md"}}))')"

summary

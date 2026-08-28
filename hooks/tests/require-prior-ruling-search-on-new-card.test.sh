#!/usr/bin/env bash
# require-prior-ruling-search-on-new-card — most "new" problems have been ruled on already, and the
# ruling is usually in a spec rather than on the board, under a name that shares no words with the
# symptom. The gate denies adding a card, or writing a DoD verdict, without a line saying which
# corpus was searched and what it returned.
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/require-prior-ruling-search-on-new-card.mjs

# --- portable activation context ---------------------------------------------------------------
AAL_PROJ="$(mktemp -d)"
mkdir -p "$AAL_PROJ/.claude"
: > "$AAL_PROJ/.claude/.autoloop"
AAL_PROJ_N="$(aal_native "$AAL_PROJ")"
aal_pin_project "$AAL_PROJ_N"
trap 'rm -rf "$AAL_PROJ"' EXIT

BOARD="$AAL_PROJ_N/.claude/BACKLOG.md"
: > "$AAL_PROJ/.claude/BACKLOG.md"

# Assembled from arguments, so no line of this source reads as a real card to an installed autoloop.
BULLET='-'
head_of()   { printf '%s [%s] %s\n' '###' "$1" "$2"; }
remedy_of() { printf '%s [%s] %s · %s=%s\n' '###' "$1" "$2" 'dod-remedy-for' "$3"; }
search_of() { printf '%s %s: %s\n' "$BULLET" 'phantom-gate' 'searched the board, the specs and the op-log for the error string, 0 hits, control hit 6 files'; }
family_of() { printf '%s %s: %s\n' "$BULLET" 'family-scan' 'family=docs/product-specs/R-widget-{plan,architecture}.md · already decided=none · sibling cards=none'; }
deferred_of() { printf '%s %s: %s\n' "$BULLET" 'phantom-gate' 'to be done later'; }
# -----------------------------------------------------------------------------------------------

ed() { # $1 = new_string, $2 = old_string (default empty)
  node -e 'process.stdout.write(JSON.stringify({tool_name:"Edit",tool_input:{file_path:process.argv[1],old_string:process.argv[3]||"",new_string:process.argv[2]}}))' \
    -- "$BOARD" "$1" "${2:-}"
}

# --- DENY: a new card with no search recorded -------------------------------------------------------
assert_deny "a new queued card" "$(ed "$(head_of QUEUED R-widget-detail)")" 'BLOCKED'
# A promise to search later is the same as no search: the card lands, and nobody comes back.
assert_deny "a deferred search" \
  "$(ed "$(head_of QUEUED R-widget-detail)
$(deferred_of)")" 'BLOCKED'

# --- ALLOW: the search, with what it returned --------------------------------------------------------
assert_allow "a search line with a result" \
  "$(ed "$(head_of QUEUED R-widget-detail)
$(search_of)")"

# --- DENY: a card claiming to belong to a family, with no family scan -----------------------------------
# A remedy card inherits a parent wave's decisions. Adding one without reading them is how a wave's
# own conclusion gets re-litigated by its own follow-up.
assert_deny "a remedy card with no family scan" \
  "$(ed "$(remedy_of QUEUED R-widget-followup R-widget-detail)
$(search_of)")" 'wave family'
assert_allow "…with the family scan" \
  "$(ed "$(remedy_of QUEUED R-widget-followup R-widget-detail)
$(search_of)
$(family_of)")"

# --- DENY: a DoD verdict with no family scan -----------------------------------------------------------
# Both directions of the verdict, because the reason text differs and each is a separate claim: one
# says the wave's purpose was met, the other that it failed. Neither is checkable without knowing
# whether the family had already written this outcome down as expected.
assert_deny "DoD-VERIFIED with no family scan" \
  "$(ed "$(head_of REVIEW R-widget-detail)
$(printf '%s %s\n' "$BULLET" 'DoD-VERIFIED: the sitemap holds every venue')")" 'FAMILY-SCAN'
assert_deny "DoD-FAILED with no family scan" \
  "$(ed "$(head_of BLOCKED R-widget-detail)
$(printf '%s %s\n' "$BULLET" 'DoD-FAILED: the sitemap still holds nothing')")" 'FAMILY-SCAN'
# The card ALREADY EXISTS when a verdict is written, so the header goes in the old text: an edit
# that carries a header the board did not have is a new card, and it owes the prior-ruling search on
# top of the family scan. Both checks firing on one payload is correct — it just makes the arm
# ambiguous, which is why this one is written the way a verdict is really written.
assert_allow "a DoD verdict with the family scan" \
  "$(ed "$(head_of REVIEW R-widget-detail)
$(printf '%s %s\n' "$BULLET" 'DoD-VERIFIED: the sitemap holds every venue')
$(family_of)" "$(head_of REVIEW R-widget-detail)")"

# --- ALLOW: edits that add no card and no verdict ---------------------------------------------------------
assert_allow "a log line on an existing card" \
  "$(ed "$(printf '%s %s\n' "$BULLET" 'log: 2026-08-27T10:00:00Z · dispatched the developer')")"
# A card that arrives already closed is a record of something finished elsewhere, not a claim that
# needs a search behind it.
assert_allow "a withdrawn card"  "$(ed "$(head_of WITHDRAWN R-widget-detail)")"
assert_allow "a done card"       "$(ed "$(head_of DONE R-widget-detail)")"
# The same header already present in the old text is not a NEW card: an edit that reshapes a card
# would otherwise be denied for adding what was already there.
assert_allow "a header that was already there" \
  "$(ed "$(head_of IN-DEV R-widget-detail)" "$(head_of QUEUED R-widget-detail)")"
assert_allow "an empty edit" "$(ed "")"

# --- ALLOW: files and tools this gate does not judge ---------------------------------------------------------
assert_allow "an archive file" \
  "$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Edit",tool_input:{file_path:process.argv[1],old_string:"",new_string:process.argv[2]}}))' \
    -- "$AAL_PROJ_N/.claude/BACKLOG-archive-01.md" "$(head_of QUEUED R-widget-detail)")"
assert_allow "not an edit at all" \
  "$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:"grep -n QUEUED board.md"}}))')"

summary

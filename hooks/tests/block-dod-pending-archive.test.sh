#!/usr/bin/env bash
# block-dod-pending-archive — archiving a card is the claim that its Definition of Done was met.
# A card whose DoD failed, is still gated, or is openly pending goes into the archive looking
# finished, and nothing ever reads it again. The gate denies the archive write in those three
# states, and each denial names a way out that does not involve deleting the evidence.
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/block-dod-pending-archive.mjs

# --- portable activation context ---------------------------------------------------------------
# 🔴 The sandbox is a NEUTRAL mktemp directory, deliberately not named after the gate. This gate
# looks for the token `DoD-PENDING`, and a directory called `aal-fx-block-dod-pending-archive`
# carries that token inside every payload that mentions a path under it: three correct ALLOW arms
# denied, with a reason quoting a marker that existed only in the fixture's own directory name.
# The rule generalises — a fixture named after the thing it tests hands its subject a corpus made
# of the subject's own vocabulary.
AAL_PROJ="$(mktemp -d)"
mkdir -p "$AAL_PROJ/.claude"; : > "$AAL_PROJ/.claude/.autoloop"
AAL_PROJ_N="$(aal_native "$AAL_PROJ")"
export CLAUDE_PROJECT_DIR="$AAL_PROJ_N"
trap 'rm -rf "$AAL_PROJ"' EXIT

ARCHIVE="$AAL_PROJ_N/.claude/BACKLOG-archive-01.md"
BOARD="$AAL_PROJ_N/.claude/BACKLOG.md"
NOTES="$AAL_PROJ_N/notes.md"
# Stamps come off the clock: a hardcoded one drifts, and the failure marker is only meaningful
# while it reads as an observation somebody made.
STAMP="$(aal_date_rel '-2 days' +%Y-%m-%dT%H:%M:%SZ)"
LATER="$(aal_date_rel '-1 day' +%Y-%m-%dT%H:%M:%SZ)"
FAILED_AT="dod-failed-at=$STAMP"
CLEARED_AT="dod-failed-cleared-at=$LATER"
# -----------------------------------------------------------------------------------------------

w() { node -e 'process.stdout.write(JSON.stringify({tool_name:"Write",tool_input:{file_path:process.argv[1],content:process.argv[2]}}))' -- "$1" "$2"; }
b() { node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:process.argv[1]}}))' -- "$1"; }

# --- DENY: the DoD ran and failed -----------------------------------------------------------------
assert_deny "a card carrying a failure stamp" \
  "$(w "$ARCHIVE" "### R-widget · $FAILED_AT · the venue never rendered")" 'CANNOT BE ARCHIVED'
assert_deny "…through Bash as well" \
  "$(b "cat card.md >> $ARCHIVE   # $FAILED_AT")" 'CANNOT BE ARCHIVED'

# --- DENY: a live gate with nowhere for the obligation to go ---------------------------------------
assert_deny "a gated DoD and no transfer" \
  "$(w "$ARCHIVE" "### R-widget
- DoD-GATED: observe-until 2026-12-01")" 'CANNOT BE ARCHIVED'

# --- DENY: an openly pending DoD -------------------------------------------------------------------
assert_deny "a pending republish" \
  "$(w "$ARCHIVE" "### R-widget
- pending republish of the dataset")" 'CANNOT BE ARCHIVED'

# --- ALLOW: the three ways out the denials name ------------------------------------------------------
# (1) the failure was cleared, with the clearing stamp LATER than the failure
assert_allow "a cleared failure" \
  "$(w "$ARCHIVE" "### R-widget · $FAILED_AT · $CLEARED_AT · re-ran the walk, green")"
# (2) the gate was resolved — the LAST DoD word is the one that counts, which is why the order of
# these two markers is the predicate rather than their mere presence.
assert_allow "gated first, verified after" \
  "$(w "$ARCHIVE" "### R-widget
- DoD-GATED: observe-until 2026-09-01
- DoD-VERIFIED: the cron fired on the 1st, evidence in the walk")"
# (3) the obligation was carried to a named successor card
assert_allow "a debt transfer to a named card" \
  "$(w "$ARCHIVE" "### R-widget
- DoD-GATED: observe-until 2026-12-01 · carried over to [[R-widget-followup]]")"
assert_allow "a resolved pending marker" \
  "$(w "$ARCHIVE" "### R-widget
- pending republish of the dataset
- DoD-VERIFIED: republished and read back from the live URL")"

# --- ALLOW: an ordinary archive write, and everything that is not one --------------------------------
assert_allow "a clean card"          "$(w "$ARCHIVE" "### R-widget
- DoD-VERIFIED: walked every layer")"
# The active board is a different file with a different gate; this one only guards the claim that
# archiving makes. Without this arm, widening the path predicate would read green.
assert_allow "the active board"      "$(w "$BOARD" "### R-widget · $FAILED_AT")"
assert_allow "an unrelated document" "$(w "$NOTES" "### R-widget · $FAILED_AT")"
assert_allow "a read of the archive" "$(b "grep -n DoD $ARCHIVE")"

summary

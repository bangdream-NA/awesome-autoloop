#!/usr/bin/env bash
# block-backlog-archive-residue — "archived" means the whole card was CUT into the archive ledger.
# A tombstone line, an `<!-- archived -->` comment or a done-badge header left on the active board
# is a card that reads as filed while still occupying the board. The gate fires on that residue.
#
# ⚠️ This gate answers on the `{"decision":"block"}` channel, not the PreToolUse permission channel,
# so its arms use assert_fires / assert_silent. Reading it with assert_deny would score every arm
# as a hole: the output is there, it just does not carry the token that helper looks for.
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/block-backlog-archive-residue.mjs

# --- portable activation context ---------------------------------------------------------------
AAL_PROJ="$(mktemp -d)"
# The gate READS the board off disk, from node, so the payload has to carry the path in node's own
# spelling (see block-truncate-existing-ledger.test.sh for what the shell spelling costs).
AAL_PROJ_N="$(cd "$AAL_PROJ" && pwd -W 2>/dev/null || pwd)"
mkdir -p "$AAL_PROJ/.claude"
: > "$AAL_PROJ/.claude/.autoloop"
export CLAUDE_PROJECT_DIR="$AAL_PROJ_N"
trap 'rm -rf "$AAL_PROJ"' EXIT

BOARD="$AAL_PROJ/.claude/BACKLOG.md"
BOARD_N="$AAL_PROJ_N/.claude/BACKLOG.md"
# -----------------------------------------------------------------------------------------------

p() { node -e 'process.stdout.write(JSON.stringify({tool_name:"Write",tool_input:{file_path:process.argv[1]}}))' -- "$1"; }

board() { printf '%s\n' "$@" > "$BOARD"; }

CLEAN_CARD='### [QUEUED] R-widget'

# --- FIRES: each residue shape on its own ---------------------------------------------------------
board "$CLEAN_CARD" '(R-old-thing -> DONE)'
assert_fires "an arrow tombstone"        "$(p "$BOARD_N")" 'ARCHIVE-RESIDUE'
board "$CLEAN_CARD" '(R-old-thing → ARCHIVED)'
assert_fires "a unicode-arrow tombstone" "$(p "$BOARD_N")" 'ARCHIVE-RESIDUE'
board "$CLEAN_CARD" '(wave-old archived 2026-08-01)'
assert_fires "the word archived"         "$(p "$BOARD_N")" 'ARCHIVE-RESIDUE'
board "$CLEAN_CARD" '<!-- archived: R-old-thing, see BACKLOG-archive-01 -->'
assert_fires "an archived comment"       "$(p "$BOARD_N")" 'ARCHIVE-RESIDUE'
board "$CLEAN_CARD" '### [DONE] R-old-thing'
assert_fires "a DONE badge header"       "$(p "$BOARD_N")" 'ARCHIVE-RESIDUE'
board "$CLEAN_CARD" '### ✅ R-old-thing'
assert_fires "a tick badge header"       "$(p "$BOARD_N")" 'ARCHIVE-RESIDUE'

# The reason names the count, so a board carrying several kinds must report several kinds — a
# report that stops at the first hit sends someone back for a second pass they did not know about.
board "$CLEAN_CARD" '(R-a -> DONE)' '<!-- archived: R-b -->' '### [DONE] R-c'
assert_fires "all three kinds are counted" "$(p "$BOARD_N")" 'tombstone line(s)'
assert_fires "…including the comment"      "$(p "$BOARD_N")" 'comment block(s)'
assert_fires "…including the badge"        "$(p "$BOARD_N")" 'done-badge header(s)'

# --- SILENT: a board with nothing left behind -----------------------------------------------------
board "$CLEAN_CARD" '- log: 2026-08-01T10:00:00Z · dispatched the developer'
assert_silent "a clean active board"     "$(p "$BOARD_N")"
board '### [REVIEW] R-widget' '- problem: the detail page renders no venue'
assert_silent "a card in review"         "$(p "$BOARD_N")"
# The badge predicate is anchored at the start of a header line: the same words inside a card's
# prose are a description of the past, not a card masquerading as filed.
board "$CLEAN_CARD" 'The previous wave was ARCHIVED after its walk, see the archive ledger.'
assert_silent "the words in ordinary prose" "$(p "$BOARD_N")"

# --- SILENT: not the active board at all ----------------------------------------------------------
printf '%s\n' '(R-old-thing -> DONE)' > "$AAL_PROJ/.claude/BACKLOG-archive-01.md"
assert_silent "the archive ledger itself, where residue BELONGS" \
  "$(p "$AAL_PROJ_N/.claude/BACKLOG-archive-01.md")"
assert_silent "a file that does not exist"  "$(p "$AAL_PROJ_N/.claude/BACKLOG.md.missing")"

summary

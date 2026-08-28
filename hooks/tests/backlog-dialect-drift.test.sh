#!/usr/bin/env bash
# backlog-dialect-drift — the sibling of the anchor gate, from the other side. That one refuses the
# write; this one sweeps the board as it stands, because a card can carry a failure written in prose
# alone and every enforcing gate will read the board as clean. It also runs as a CLI, which is how a
# person asks the same question on demand.
source "$(dirname "$0")/_lib.sh"
HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$HOOKS_DIR/backlog-dialect-drift.mjs"

# --- portable activation context ---------------------------------------------------------------
AAL_PROJ="$(mktemp -d)"
mkdir -p "$AAL_PROJ/.claude"
: > "$AAL_PROJ/.claude/.autoloop"
AAL_PROJ_N="$(aal_native "$AAL_PROJ")"
aal_pin_project "$AAL_PROJ_N"
export AAL_BACKLOG="$AAL_PROJ_N/.claude/BACKLOG.md"
trap 'rm -rf "$AAL_PROJ"' EXIT

STAMP="$(aal_date_rel '-2 hours' +%Y-%m-%dT%H:%M:%SZ)"
FAIL_KEY=dod-failed-at
card() { printf '%s [%s] %s%s\n' '###' 'BLOCKED' "$1" "$2"; }
board() { printf '# Backlog\n\n%s\n' "$1" > "$AAL_PROJ/.claude/BACKLOG.md"; }
p() { node -e 'process.stdout.write(JSON.stringify({}))'; }
# -----------------------------------------------------------------------------------------------

# --- FIRES: a live failure that only exists in prose --------------------------------------------------
board "$(card R-widget ' · DoD-FAILED: the sitemap still holds nothing')"
assert_fires "prose-only failure"      "$(p)" 'DIALECT DRIFT'
assert_fires "…and it names the card"  "$(p)" 'R-widget'

# --- QUIET: the same claim with the field the enforcing gate reads ---------------------------------------
board "$(card R-widget " · DoD-FAILED: the sitemap still holds nothing · $FAIL_KEY=$STAMP")"
assert_quiet "the anchor present" "$(p)"
# A failure recorded as released is not a live one; the word on the same line is what says so.
board "$(card R-widget ' · DoD-FAILED: the sitemap held nothing, released after the republish')"
assert_quiet "a released failure" "$(p)"

# --- QUIET: boards with no failure at all -----------------------------------------------------------------
board "$(printf '%s [%s] %s\n' '###' 'IN-DEV' 'R-widget')"
assert_quiet "an ordinary board" "$(p)"
board ""
assert_quiet "an empty board"    "$(p)"

# --- QUIET: no board to read --------------------------------------------------------------------------------
rm -f "$AAL_PROJ/.claude/BACKLOG.md"
assert_quiet "no board on disk" "$(p)"

# --- the same predicate, driven as a command ------------------------------------------------------------------
# The CLI is how a person asks on demand, and its exit code is what a script would branch on — so both
# directions need checking, not just the printed text.
board "$(card R-widget ' · DoD-FAILED: the sitemap still holds nothing')"
out="$(node "$HOOK" --board "$AAL_PROJ_N/.claude/BACKLOG.md" --list 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'DIALECT DRIFT (live claim'; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("CLI-DIRTY: rc=$rc out='$(printf '%s' "$out" | tail -c 120)'")
fi
board "$(card R-widget " · DoD-FAILED: the sitemap still holds nothing · $FAIL_KEY=$STAMP")"
out="$(node "$HOOK" --board "$AAL_PROJ_N/.claude/BACKLOG.md" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("CLI-CLEAN: rc=$rc on a board with the anchor present")
fi
# A board it cannot read is an error, not a clean result: exit 2 keeps a script from reading "no
# drift" out of "no file".
out="$(node "$HOOK" --board "$AAL_PROJ_N/.claude/no-such-board.md" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("CLI-MISSING: rc=$rc for a board that does not exist — a missing file must not read as clean")
fi

summary

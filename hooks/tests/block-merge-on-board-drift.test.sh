#!/usr/bin/env bash
# block-merge-on-board-drift — merging while the board disagrees with the repository writes another
# fact on top of a picture that is already wrong. The gate reads the reconciler's own state file and
# denies the merge while it says the board is dirty — but only while that reading is fresh, because a
# stale one says nothing about today.
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/block-merge-on-board-drift.sh

# --- portable activation context ---------------------------------------------------------------
AAL_TMP="$(mktemp -d)"
mkdir -p "$AAL_TMP/repo/.claude"
: > "$AAL_TMP/repo/.claude/.autoloop"
AAL_TMP_N="$(aal_native "$AAL_TMP")"
REPO_N="$AAL_TMP_N/repo"
export CLAUDE_PROJECT_DIR="$REPO_N"
trap 'rm -rf "$AAL_TMP"' EXIT

STATE="$AAL_TMP/repo/.claude/.reconcile-state.json"
# The gate resolves the project from a LEADING `cd` in the command itself, which is how the merge is
# always written, so every payload below carries one.
state() { # $1 = dirty (true/false), $2 = drift count
  printf '{"ts":0,"dirty": %s,"driftCount": %s,"report":"drift"}\n' "$1" "$2" > "$STATE"
}
p() { node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:process.argv[1]}}))' -- "$1"; }
MERGE="cd $REPO_N && gh pr merge 12 --squash --delete-branch"
# -----------------------------------------------------------------------------------------------

# --- DENY: the reconciler says the board is dirty -------------------------------------------------------
state true 3
assert_deny "a dirty board"          "$(p "$MERGE")" 'DRIFT'
assert_deny "…and it carries the count" "$(p "$MERGE")" '3'

# --- ALLOW: a clean reading -------------------------------------------------------------------------------
state false 0
assert_allow "a clean board"         "$(p "$MERGE")"

# --- ALLOW: the reading is too old to mean anything --------------------------------------------------------
# Twelve hours. A stale file is not evidence about now, and treating it as evidence would leave the
# merge blocked by a measurement nobody remembers taking.
state true 3
aal_touch_rel '-2 days' "$STATE"
assert_allow "a reading from two days ago" "$(p "$MERGE")"
state true 3

# --- ALLOW: nothing to read ---------------------------------------------------------------------------------
rm -f "$STATE"
assert_allow "no state file"         "$(p "$MERGE")"
state true 3

# --- ALLOW: commands that are not a merge, or that name no project ---------------------------------------------
assert_allow "a merge with no leading cd" "$(p "gh pr merge 12 --squash")"
assert_allow "gh pr view"                 "$(p "cd $REPO_N && gh pr view 12 --json state")"
assert_allow "a push"                     "$(p "cd $REPO_N && git push origin main")"
assert_allow "an unrelated command"       "$(p "git status --porcelain")"

summary

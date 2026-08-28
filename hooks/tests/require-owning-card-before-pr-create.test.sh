#!/usr/bin/env bash
# require-owning-card-before-pr-create — opening a PR is a scope freeze. Two things have to be true
# first: a card on the board owns this branch, and the agent that delivered it has left the roster.
# Freezing before the hand-over creates a dirty tree, a void SHA and an occupied worktree, and every
# one of those is self-inflicted.
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/require-owning-card-before-pr-create.mjs

# --- portable activation context ---------------------------------------------------------------
AAL_TMP="$(mktemp -d)"
trap 'rm -rf "$AAL_TMP"' EXIT

REPO="$AAL_TMP/repo"
mkdir -p "$REPO/.claude"
REPO_N="$(aal_mkrepo "$REPO")"
: > "$REPO/.claude/.autoloop"
aal_pin_project "$REPO_N"
export AAL_BACKLOG="$REPO_N/.claude/BACKLOG.md"
# The roster is named through its seam rather than read from the machine: an empty value means "nobody
# is holding anything", which is the state a lead is in when the hand-over has happened.
export AAL_ROSTER_NAMES=''
git -C "$REPO" checkout -q -b feat/r-widget-detail

BULLET='-'
card()    { printf '# Backlog\n\n%s [%s] %s\n' '###' 'REVIEW' "$1" > "$REPO/.claude/BACKLOG.md"; }
card_with_alias() { printf '# Backlog\n\n%s [%s] %s\n%s %s: %s\n' '###' 'REVIEW' "$1" "$BULLET" 'aliases' "$2" > "$REPO/.claude/BACKLOG.md"; }
# -----------------------------------------------------------------------------------------------

p() { node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",cwd:process.argv[2],tool_input:{command:process.argv[1]}}))' -- "$1" "$REPO_N"; }
PRCMD="gh pr create --title 'feat: widget' --body 'Refs #42'"

# --- DENY: no card owns this branch ------------------------------------------------------------------
card R-something-else
assert_deny "no owning card" "$(p "$PRCMD")" 'no owning card on the board'

# --- ALLOW: a card whose slug resolves to the branch ----------------------------------------------------
card R-widget-detail
assert_allow "the card's own branch" "$(p "$PRCMD")"
# The other route the denial names: the branch spelled out on the aliases line, for a card whose slug
# was chosen before the branch existed.
card_with_alias R-venue-empty 'feat/r-widget-detail'
assert_allow "the branch named in aliases" "$(p "$PRCMD")"

# --- DENY: the delivering agent is still on the roster -----------------------------------------------------
card R-widget-detail
AAL_ROSTER_NAMES='team-lead,dev-widget-detail'
assert_deny "its developer has not left" "$(p "$PRCMD")" 'still on the roster'
# The lead is always on the roster and is not a holder; without this arm the check would deny every
# PR the lead ever opens.
AAL_ROSTER_NAMES='team-lead'
assert_allow "only the lead is listed" "$(p "$PRCMD")"
# An agent from a DIFFERENT wave holds a different tree, so it cannot be the one that has not handed
# over. The token match is what separates the two, and it is the part most likely to over-fire.
AAL_ROSTER_NAMES='team-lead,dev-other-wave'
assert_allow "an agent from another wave" "$(p "$PRCMD")"
AAL_ROSTER_NAMES=''

# --- ALLOW: branches that belong to nobody here --------------------------------------------------------------
card R-something-else
assert_allow "a dependabot branch" "$(p "gh pr create --head dependabot/npm_and_yarn/left-pad-1.3.0 --title 'chore: bump' --body ''")"
assert_allow "a renovate branch"   "$(p "gh pr create --head renovate/node-22 --title 'chore: bump' --body ''")"

# --- ALLOW: commands that are not opening a PR ----------------------------------------------------------------
assert_allow "gh pr view"      "$(p "gh pr view 12 --json state")"
assert_allow "a push"          "$(p "git push -u origin feat/r-widget-detail")"
assert_allow "the phrase as data" "$(p "grep -rn 'gh pr create' docs/")"

# --- ALLOW: nothing to read ----------------------------------------------------------------------------------------
# With no board there is no card to be missing, and a gate that denied here would block the first PR
# of every repository that has not adopted a board yet.
rm -f "$REPO/.claude/BACKLOG.md"
assert_allow "no board at all" "$(p "$PRCMD")"

summary

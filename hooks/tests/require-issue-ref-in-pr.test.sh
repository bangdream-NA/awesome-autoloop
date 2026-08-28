#!/usr/bin/env bash
# require-issue-ref-in-pr — a PR that names no issue leaves the tracker and the branch with no link
# between them, and the number is on the card already. The gate denies `gh pr create` with no `#N`
# in the command, and separately denies a PR whose whole diff is a plan document.
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/require-issue-ref-in-pr.mjs

# --- portable activation context ---------------------------------------------------------------
AAL_TMP="$(mktemp -d)"
trap 'rm -rf "$AAL_TMP"' EXIT

# This gate runs `git` against the payload's cwd, so the fixture builds THROWAWAY repositories
# rather than reading whichever one it happens to live in. aal_mkrepo / aal_commit_file live in
# _lib.sh so that the several gates needing a repo all build the same one.
mkrepo() { # $1 = dir name -> prints the path in node's spelling
  mkdir -p "$AAL_TMP/$1/.claude" "$AAL_TMP/$1/docs/product-specs"
  aal_mkrepo "$AAL_TMP/$1"
}

card_header() { printf '### [%s] %s\n' "$1" "$2"; }

REPO="$AAL_TMP/repo"
REPO_N="$(mkrepo repo)"
export CLAUDE_PROJECT_DIR="$REPO_N"
: > "$REPO/.claude/.autoloop"
card_header IN-DEV R-widget > "$REPO/.claude/BACKLOG.md"
git -C "$REPO" checkout -q -b feat/r-widget
aal_commit_file "$REPO" src/widget.ts 'export const widget = 1'
# -----------------------------------------------------------------------------------------------

p() { # $1 = command, $2 = cwd
  node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:process.argv[1]},cwd:process.argv[2]}))' -- "$1" "$2"
}

# --- DENY: no issue number anywhere in the command -----------------------------------------------
assert_deny "a PR body with no reference" \
  "$(p "gh pr create --title 'feat: widget' --body 'implements the widget'" "$REPO_N")" 'references no issue'
# When the board has no tracker line for this branch, the denial says so and names the sync command
# instead of inventing a number. That distinction is the whole point of the gate: a guessed number
# links the PR to somebody else's issue, which is worse than no link at all.
assert_deny "…and it refuses to invent one" \
  "$(p "gh pr create --title 'feat: widget' --body 'implements the widget'" "$REPO_N")" 'Could not resolve'
# 🔴 NOT ASSERTED: the other half of that branch — a card that DOES carry a tracker line, where the
# denial quotes the number. Writing that arm means putting the literal field line into this file,
# and in an installed autoloop that line is owned by the sync tool: the environment refuses to write
# any file containing it, this fixture included. The gap is in the fixture, not in the gate; the
# hint code path is three lines below the one exercised above. Naming it here rather than leaving a
# silent hole, because a reader counting arms would otherwise read this file as covering both.

# --- ALLOW: the reference, in either spelling ------------------------------------------------------
assert_allow "Refs in the body"      "$(p "gh pr create --title 'feat: widget' --body 'implements the widget. Refs #42'" "$REPO_N")"
assert_allow "Closes"                "$(p "gh pr create --title 'feat: widget' --body 'Closes #42'" "$REPO_N")"
# --body-file / -F put the body in a file the gate cannot read, so it stands aside rather than
# guessing. Pinned because the alternative — denying every -F — would make the documented way of
# writing a long PR body impossible.
assert_allow "--body-file"           "$(p "gh pr create --title 'feat: widget' --body-file /tmp/body.md" "$REPO_N")"
assert_allow "-F"                    "$(p "gh pr create --title 'feat: widget' -F /tmp/body.md" "$REPO_N")"

# --- ALLOW: not a PR creation ----------------------------------------------------------------------
assert_allow "gh pr view"            "$(p "gh pr view 12 --json state" "$REPO_N")"
assert_allow "an unrelated command"  "$(p "git status --porcelain" "$REPO_N")"

# --- DENY, on the other predicate: a branch whose entire diff is a plan ---------------------------
PLANREPO="$AAL_TMP/planrepo"
PLANREPO_N="$(mkrepo planrepo)"
card_header QUEUED R-widget > "$PLANREPO/.claude/BACKLOG.md"
git -C "$PLANREPO" checkout -q -b feat/r-widget
aal_commit_file "$PLANREPO" docs/product-specs/R-widget-plan.md '# R-widget plan'
assert_deny "a plan-only branch opening a PR" \
  "$(p "gh pr create --title 'plan: widget' --body 'the plan. Refs #77'" "$PLANREPO_N")" 'a planning wave does not open a PR'
# The verdict is "nothing BUT a plan": one line of implementation alongside it and this is a code
# wave again. Without this arm, tightening the predicate to "touches a plan" would read green.
aal_commit_file "$PLANREPO" src/widget.ts 'export const widget = 1'
assert_allow "a mixed plan-plus-code branch" \
  "$(p "gh pr create --title 'feat: widget' --body 'implements the plan. Refs #77'" "$PLANREPO_N")"

# 🔴 A single-digit reference. The pattern used to demand TWO to five digits, so a repository's
# first nine issues could never satisfy this gate: the denial told the operator to take the number
# from the card, and taking it produced the same denial. That is a gate nobody can obey, and every
# adopter meets it on their first nine PRs.
assert_allow "a single-digit reference counts" \
  "$(p "gh pr create --title 'feat: widget' --body 'implements the plan. Refs #7'" "$PLANREPO_N")"
# 🔴 The load-bearing half: loosening the lower bound must not loosen anything else. A six-digit
# number is still out of range, and a hex colour is not an issue reference — both would match a
# careless `#\d+`, and a must-red arm cannot see either.
assert_deny "six digits is still out of range" \
  "$(p "gh pr create --title 'feat: widget' --body 'implements the plan. Refs #123456'" "$PLANREPO_N")" 'references no issue'
assert_deny "a hex colour is not a reference" \
  "$(p "gh pr create --title 'feat: widget' --body 'the badge is #1a2b3c now'" "$PLANREPO_N")" 'references no issue'

# --- ALLOW: fail-open where the gate cannot know ----------------------------------------------------
# No board on disk ⇒ nothing to take a number from. A gate that denied here would block every
# adopter who has not created a board yet, and it could not name a number if it wanted to.
BARE="$AAL_TMP/bare"
BARE_N="$(mkrepo bare)"
git -C "$BARE" checkout -q -b feat/r-widget
assert_allow "a repository with no board" \
  "$(p "gh pr create --title 'feat: widget' --body 'no reference here'" "$BARE_N")"

summary

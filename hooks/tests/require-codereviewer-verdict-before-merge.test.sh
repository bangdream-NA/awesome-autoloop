#!/usr/bin/env bash
# require-codereviewer-verdict-before-merge — a merge is the moment the verdict has to exist, and it
# has to have been written by the role whose verdict counts. The gate denies `gh pr merge` when the
# PR has no review artifact, or when the artifact carries no code-reviewer attestation.
source "$(dirname "$0")/_lib.sh"
HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$HOOKS_DIR/require-codereviewer-verdict-before-merge.sh"

# --- portable activation context ---------------------------------------------------------------
AAL_TMP="$(mktemp -d)"
trap 'rm -rf "$AAL_TMP"' EXIT

REPO="$AAL_TMP/repo"
mkdir -p "$REPO/.claude/reviews"
REPO_N="$(aal_mkrepo "$REPO")"
: > "$REPO/.claude/.autoloop"
export CLAUDE_PROJECT_DIR="$REPO_N"
# The gate resolves the project from a leading `cd`, then from CLAUDE_PROJECT_DIR, then from the
# shell's own directory. Pinning the process CWD as well keeps the last fallback from reaching
# whatever checkout the suite was launched in.
cd "$REPO" || exit 1

verdict() { # $1 = pr number, $2 = body
  printf '%s\n' "$2" > "$REPO/.claude/reviews/pr$1-r1.md"
}
# -----------------------------------------------------------------------------------------------

p() { node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:process.argv[1]},cwd:process.argv[2]}))' -- "$1" "$REPO_N"; }

# --- DENY: nothing was reviewed --------------------------------------------------------------------
assert_deny "no verdict file at all" "$(p "gh pr merge 12 --squash --delete-branch")" 'dispatch a FRESH code-reviewer'

# --- DENY: something was written, but not by a code-reviewer ----------------------------------------
# The attestation is the point. A verdict written by any other role reads the same to a merge script
# and to a person skimming the directory, which is exactly why the gate wants the line rather than
# the file's existence.
verdict 12 "# PR 12
Verdict: APPROVED
Reviewer-type: plan-reviewer"
assert_deny "a verdict from the wrong role" "$(p "gh pr merge 12 --squash --delete-branch")" 'NO .Reviewer-type: code-reviewer'
verdict 12 "# PR 12
Verdict: APPROVED
Looks good to me."
assert_deny "a verdict with no attestation line" "$(p "gh pr merge 12 --squash --delete-branch")" 'NO .Reviewer-type: code-reviewer'

# --- ALLOW: the attested verdict ---------------------------------------------------------------------
verdict 12 "# PR 12
Verdict: APPROVED
Reviewer-type: code-reviewer"
assert_allow "an attested verdict" "$(p "gh pr merge 12 --squash --delete-branch")"

# --- the LATEST round is the one that counts ----------------------------------------------------------
# Rounds sort by version, not lexically: r10 comes after r9, and a lexical sort would answer with a
# stale round for every PR that went past nine. The pair below is the discriminator.
printf '# PR 12\nReviewer-type: code-reviewer\n' > "$REPO/.claude/reviews/pr12-r9.md"
printf '# PR 12\nReviewer-type: plan-reviewer\n' > "$REPO/.claude/reviews/pr12-r10.md"
assert_deny "round 10 beats round 9" "$(p "gh pr merge 12 --squash --delete-branch")" 'NO .Reviewer-type: code-reviewer'
rm -f "$REPO/.claude/reviews/pr12-r9.md" "$REPO/.claude/reviews/pr12-r10.md"

# --- ALLOW: a different PR number is a different question -----------------------------------------------
# pr12 is attested; the merge names 13, which has nothing. Without this arm the gate could be reading
# ANY verdict in the directory and every arm above would still pass.
assert_deny "another PR with no verdict" "$(p "gh pr merge 13 --squash --delete-branch")" 'dispatch a FRESH code-reviewer'

# --- ALLOW: commands that are not a merge -----------------------------------------------------------------
assert_allow "gh pr view"          "$(p "gh pr view 13 --json state")"
assert_allow "a checks watch"      "$(p "gh pr checks 13 --watch")"
assert_allow "the phrase as data"  "$(p "grep -rn 'gh pr merge' docs/")"
assert_allow "an unrelated command" "$(p "git status --porcelain")"

# --- ALLOW: a merge with no resolvable PR number ------------------------------------------------------------
# With no number in the command and no gh to ask, the gate cannot name which verdict it wants, so it
# stands aside rather than denying a question it cannot phrase. Pinned because the alternative reads
# identically green while denying every numberless merge.
assert_allow "a merge naming no number" "$(p "gh pr merge --squash")"

summary

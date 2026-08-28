#!/usr/bin/env bash
# block-non-codereviewer-mode-b — a PR code review carries a verdict that gates the merge, and only
# the code-reviewer role writes one. Handing that brief to a general agent produces an opinion that
# looks like a verdict and lands nowhere. The gate denies the dispatch by role.
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/block-non-codereviewer-mode-b.sh

# --- portable activation context ---------------------------------------------------------------
AAL_PROJ=/tmp/aal-fx-block-non-codereviewer-mode-b
rm -rf "$AAL_PROJ"; mkdir -p "$AAL_PROJ/.claude"; : > "$AAL_PROJ/.claude/.autoloop"
export CLAUDE_PROJECT_DIR="$AAL_PROJ"
trap 'rm -rf "$AAL_PROJ"' EXIT
# -----------------------------------------------------------------------------------------------

a() { # $1 = subagent_type, $2 = prompt
  node -e 'process.stdout.write(JSON.stringify({tool_name:"Agent",tool_input:{subagent_type:process.argv[1],name:"agent-x",prompt:process.argv[2]}}))' -- "$1" "$2"
}

# --- DENY: a review brief handed to a role that cannot issue a verdict ---------------------------
assert_deny "general-purpose asked to review the PR" \
  "$(a general-purpose "Do a code review of the PR and report findings")" 'Mode-B'
assert_deny "a developer asked to review this PR" \
  "$(a developer "Please review this PR before we merge")" 'Mode-B'
assert_deny "an architect asked to review the open PR" \
  "$(a architect "Review the open PR and tell me if it is safe")" 'Mode-B'
assert_deny "the mode-b token spelled out" \
  "$(a general-purpose "Run a mode-b-code-review over the branch")" 'Mode-B'

# --- ALLOW: the roles that legitimately do it -----------------------------------------------------
assert_allow "the code-reviewer itself" \
  "$(a code-reviewer "Do a code review of the PR and write the verdict file")"
# plan-reviewer, planner and uiux-designer are exempt by role: their briefs routinely quote the
# pipeline's vocabulary, and denying them would deny the sentence rather than the misroute.
assert_allow "a plan-reviewer whose brief quotes the phrase" \
  "$(a plan-reviewer "The plan says the code review of the PR happens after the developer")"
assert_allow "a planner whose brief quotes the phrase" \
  "$(a planner "Note in the plan that a review of this PR is the last step")"
assert_allow "a uiux-designer" \
  "$(a uiux-designer "Design the empty state; the code review of the PR comes later")"

# --- ALLOW: any other work for a non-reviewer role --------------------------------------------------
assert_allow "a developer implementing"   "$(a developer "Implement the locks in the architecture doc")"
assert_allow "a general-purpose search"   "$(a general-purpose "Find every caller of the venue helper")"
# "review" on its own is an ordinary English word; the predicate wants the PR as its object.
assert_allow "reviewing something that is not a PR" \
  "$(a general-purpose "Review the runbook and tell me which paragraph is now false")"
assert_allow "not an Agent dispatch" \
  "$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:"gh pr view 12"}}))')"

summary

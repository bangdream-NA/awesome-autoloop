#!/usr/bin/env bash
# block-agent-role-boundary-violation — the pipeline has no architecture-review step, and each role
# authors exactly one document. A brief that asks a role for somebody else's artifact produces a
# document nobody downstream reads. The gate denies the three inversions it can see in a brief.
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/block-agent-role-boundary-violation.sh

# --- portable activation context ---------------------------------------------------------------
AAL_PROJ=/tmp/aal-fx-block-agent-role-boundary-violation
rm -rf "$AAL_PROJ"; mkdir -p "$AAL_PROJ/.claude"; : > "$AAL_PROJ/.claude/.autoloop"
export CLAUDE_PROJECT_DIR="$AAL_PROJ"
trap 'rm -rf "$AAL_PROJ"' EXIT
# -----------------------------------------------------------------------------------------------

a() { # $1 = subagent_type, $2 = prompt
  node -e 'process.stdout.write(JSON.stringify({tool_name:"Agent",tool_input:{subagent_type:process.argv[1],name:"agent-x",prompt:process.argv[2]}}))' -- "$1" "$2"
}

# --- DENY: a plan-reviewer asked to produce an ARCHITECTURE verdict --------------------------------
assert_deny "verdict path names an arch review" \
  "$(a plan-reviewer "Review it and write .claude/reviews/R-widget-planrev-arch-r1.md")" 'only review PLAN documents'
assert_deny "ledger field says architecture" \
  "$(a plan-reviewer "Append a row with \"reviewed\": \"architecture r1\" when you are done")" 'only review PLAN documents'

# --- DENY: the two authorship inversions ------------------------------------------------------------
assert_deny "an architect told to deliver a plan" \
  "$(a architect "You deliver docs/product-specs/R-widget-plan.md by the end of the round")" 'never .-plan.md'
assert_deny "a planner told to deliver an architecture" \
  "$(a planner "You deliver docs/product-specs/R-widget-architecture.md with the locks")" 'never .-architecture.md'

# --- ALLOW: each role asked for its OWN artifact ----------------------------------------------------
assert_allow "a plan-reviewer reviewing a plan" \
  "$(a plan-reviewer "Review the PLAN doc r2 and land the verdict at .claude/reviews/R-widget-planrev-r2.md")"
assert_allow "an architect delivering an architecture" \
  "$(a architect "You deliver docs/product-specs/R-widget-architecture.md")"
assert_allow "a planner delivering a plan" \
  "$(a planner "You deliver docs/product-specs/R-widget-plan.md")"
# An architect READS the plan in every wave: the predicate has to separate "deliver" from "read",
# or the gate would deny the normal brief for the role it is protecting.
assert_allow "an architect reading the plan" \
  "$(a architect "Read docs/product-specs/R-widget-plan.md in full before you write the locks")"
assert_allow "a developer reading both docs" \
  "$(a developer "Read docs/product-specs/R-widget-plan.md and R-widget-architecture.md, then implement")"

# --- ALLOW: the words as ordinary subject matter -----------------------------------------------------
assert_allow "a code-reviewer whose brief mentions the paths" \
  "$(a code-reviewer "Check that the PR matches docs/product-specs/R-widget-architecture.md")"
assert_allow "not an Agent dispatch" \
  "$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:"ls .claude/reviews"}}))')"

summary

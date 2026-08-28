#!/usr/bin/env bash
# block-duplicate-planner-dispatch — a second round-1 planner aimed at a wave that already has a
# plan forks the spec: two documents, one card, and whichever the next baton happens to open wins.
# The gate denies the dispatch when a plan doc for that wave already exists, and yields to an
# explicit re-plan token.
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/block-duplicate-planner-dispatch.mjs

# --- portable activation context ---------------------------------------------------------------
AAL_TMP="$(mktemp -d)"
trap 'rm -rf "$AAL_TMP"' EXIT

REPO="$AAL_TMP/repo"
mkdir -p "$REPO/.claude/reviews" "$REPO/docs/product-specs"
REPO_N="$(aal_mkrepo "$REPO")"
: > "$REPO/.claude/.autoloop"
# Pin the resolution. Without this the gate asks lib/is-autoloop-lead.mjs which project this
# session belongs to, and inside an installation that answers with the operator's REAL repo rather
# than the synthetic one built above — measured here: resolveRepo returned the installed project
# while the payload's cwd said otherwise, and all three deny arms went silent.
aal_pin_project "$REPO_N"
printf '# R-widget-detail plan\n' > "$REPO/docs/product-specs/R-widget-detail-plan.md"
# -----------------------------------------------------------------------------------------------

a() { # $1 = subagent_type, $2 = name, $3 = prompt
  node -e 'process.stdout.write(JSON.stringify({tool_name:"Agent",tool_input:{subagent_type:process.argv[1],name:process.argv[2],prompt:process.argv[3]},cwd:process.argv[4]}))' \
    -- "$1" "$2" "$3" "$REPO_N"
}

# --- DENY: a planner aimed at a wave that already has a plan on disk ------------------------------
assert_deny "planner for a wave with a plan" \
  "$(a planner planner-widget "Write the plan for wave **R-widget-detail**")" 'DUPLICATE-PLANNER'
# The wave name is read from the prompt's anchor OR from the first slug in the name — a dispatch
# that never spells out "for wave **…**" is the common shape, and it has to be caught too.
assert_deny "…resolved from the agent name alone" \
  "$(a planner R-widget-detail-planner "Please produce the plan document.")" 'DUPLICATE-PLANNER'
# The role can also be carried by the NAME rather than by subagent_type; a dispatch that spells the
# role only in the name is still a planner dispatch.
assert_deny "…role carried by the name" \
  "$(a general-purpose planner-widget "Write the plan for wave **R-widget-detail**")" 'DUPLICATE-PLANNER'

# --- ALLOW: a wave with no plan yet ---------------------------------------------------------------
assert_allow "planner for a fresh wave" \
  "$(a planner planner-fresh "Write the plan for wave **R-something-else**")"
# A prefix match needs THREE segments before it counts, so a short name cannot swallow every wave
# that starts with the same word. Without this arm, dropping that condition would look green.
assert_allow "a short wave name is not a prefix match" \
  "$(a planner planner-w "Write the plan for wave **R-widget**")"

# --- ALLOW: the documented re-plan token ----------------------------------------------------------
assert_allow "an explicit REPLAN-OK" \
  "$(a planner planner-widget "Write the plan for wave **R-widget-detail**. # REPLAN-OK: the premise was superseded by the merged architecture lock")"

# --- ALLOW: any other role, and any other tool ----------------------------------------------------
# The next steps the denial itself prescribes must stay dispatchable, or the gate would close the
# only exits it offers.
assert_allow "a plan-reviewer for the same wave" \
  "$(a plan-reviewer planrev-widget "Review the plan for wave **R-widget-detail**")"
assert_allow "an architect for the same wave" \
  "$(a architect arch-widget "Write the architecture for wave **R-widget-detail**")"
assert_allow "a developer for the same wave" \
  "$(a developer dev-widget "Implement wave **R-widget-detail**")"
assert_allow "not an Agent dispatch at all" \
  "$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:"ls docs/product-specs"}}))')"

# --- ALLOW: a dispatch that names no wave ----------------------------------------------------------
# Nothing to compare against ⇒ the gate stands aside rather than guessing which wave was meant.
assert_allow "a planner naming no wave" \
  "$(a planner planner-anon "Draft a plan for the thing we discussed.")"

summary

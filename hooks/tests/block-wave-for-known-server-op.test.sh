#!/usr/bin/env bash
# block-wave-for-known-server-op — opening a wave to plan something that is already written down is a
# week spent rediscovering a runbook. The gate denies dispatching the planning roles when the card's
# own fix line points at a runbook that exists and says to follow it.
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/block-wave-for-known-server-op.mjs

# --- portable activation context ---------------------------------------------------------------
AAL_PROJ="$(mktemp -d)"
mkdir -p "$AAL_PROJ/.claude" "$AAL_PROJ/docs/runbooks"
: > "$AAL_PROJ/.claude/.autoloop"
AAL_PROJ_N="$(aal_native "$AAL_PROJ")"
aal_pin_project "$AAL_PROJ_N"
export AAL_BACKLOG="$AAL_PROJ_N/.claude/BACKLOG.md"
trap 'rm -rf "$AAL_PROJ"' EXIT

# The runbook has to EXIST: a fix line citing a document nobody wrote is a wave, not a rerun, and
# that is the difference this gate turns on.
printf '# app deploy\n\n## Phase A\n\nInstall the wrapper.\n' > "$AAL_PROJ/docs/runbooks/app-deploy.md"

BULLET='-'
# The header carries a trailing field, the way a real card does. The block lookup requires whitespace
# or a separator AFTER the slug, so a header that ENDS on the slug matches nothing and the gate stands
# aside — which reads exactly like a gate that decided the card was fine.
card() { printf '# Backlog\n\n%s [%s] %s · stage=new\n%s %s: %s\n' '###' 'QUEUED' "$1" "$BULLET" 'fix' "$2" > "$AAL_PROJ/.claude/BACKLOG.md"; }
# -----------------------------------------------------------------------------------------------

a() { # $1 = subagent_type, $2 = prompt
  node -e 'process.stdout.write(JSON.stringify({tool_name:"Agent",tool_input:{subagent_type:process.argv[1],name:"agent-x",prompt:process.argv[2]}}))' -- "$1" "$2"
}
BRIEF='# CARD: R-widget-install
Plan the installation.'

# --- DENY: the fix is "follow the runbook", for each planning role ---------------------------------------
card R-widget-install 'follow docs/runbooks/app-deploy.md Phase A on the box'
assert_deny "a planner"        "$(a planner "$BRIEF")"       'this is not a wave'
assert_deny "a plan-reviewer"  "$(a plan-reviewer "$BRIEF")" 'this is not a wave'
assert_deny "an architect"     "$(a architect "$BRIEF")"     'this is not a wave'

# --- ALLOW: the roles that carry the work out ---------------------------------------------------------------
# A developer and a reviewer are downstream of the decision this gate is about; denying them would
# stop the very execution it is asking for.
assert_allow "a developer"     "$(a developer "$BRIEF")"
assert_allow "a code-reviewer" "$(a code-reviewer "$BRIEF")"

# --- ALLOW: the documented way to say the runbook falls short --------------------------------------------------
assert_allow "the insufficiency token" \
  "$(a planner "$BRIEF
# RUNBOOK-INSUFFICIENT: Phase A stops at the wrapper and says nothing about the unit file this needs")"

# --- ALLOW: cards whose fix is not a rerun ---------------------------------------------------------------------
# Three separate reasons, each its own arm: no runbook named, a runbook that does not exist, and a
# citation with no instruction to follow it.
card R-widget-install 'rewrite the venue helper so it returns a slug'
assert_allow "no runbook cited"          "$(a planner "$BRIEF")"
card R-widget-install 'follow docs/runbooks/no-such-runbook.md Phase A'
assert_allow "a runbook that is not there" "$(a planner "$BRIEF")"
card R-widget-install 'the behaviour is described in docs/runbooks/app-deploy.md, but the code does not match it'
assert_allow "cited without a run verb"  "$(a planner "$BRIEF")"

# --- ALLOW: nothing to look up -------------------------------------------------------------------------------------
card R-other 'follow docs/runbooks/app-deploy.md Phase A'
assert_allow "the card is not on the board" "$(a planner "$BRIEF")"
assert_allow "the brief names no card"      "$(a planner "Plan the installation.")"
assert_allow "not an Agent dispatch" \
  "$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:"ls docs/runbooks"}}))')"

summary

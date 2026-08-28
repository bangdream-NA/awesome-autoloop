#!/usr/bin/env bash
# remind-shutdown-predecessor-on-dispatch — one wave, one worktree, and the next baton inherits it.
# Dispatching the next role while the previous one is still on the roster puts two agents in one tree,
# and the loser's work disappears silently. This reminds at the moment of dispatch, when it is still
# one message to fix.
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/remind-shutdown-predecessor-on-dispatch.sh

# --- portable activation context ---------------------------------------------------------------
AAL_TMP="$(mktemp -d)"
mkdir -p "$AAL_TMP/proj/.claude" "$AAL_TMP/teams/team-a"
: > "$AAL_TMP/proj/.claude/.autoloop"
AAL_TMP_N="$(aal_native "$AAL_TMP")"
export CLAUDE_PROJECT_DIR="$AAL_TMP_N/proj"
# The roster directory is a seam. Left alone this would read the operator's live teams and answer
# from whoever happens to be running right now.
export TEAM_ROSTER_DIR="$AAL_TMP_N/teams"
trap 'rm -rf "$AAL_TMP"' EXIT

# Roster entries carry a NAME and an agentType, and the type is what the lookup matches on: a member
# written with only a name is invisible to it, which reads as an empty roster rather than as a
# malformed one.
roster() { # each argument is name:agentType
  node -e '
const fs = require("fs");
const members = process.argv.slice(2).map((s) => {
  const i = s.indexOf(":");
  return { name: i < 0 ? s : s.slice(0, i), agentType: i < 0 ? "" : s.slice(i + 1), joinedAt: new Date().toISOString() };
});
fs.writeFileSync(process.argv[1], JSON.stringify({ members }));' -- "$AAL_TMP/teams/team-a/config.json" "$@"
}
# The team name is read from tool_input, not from the top level of the payload — putting it at the
# top level resolves no roster at all, which the gate reports the same way as "nobody is holding
# anything": by saying nothing.
a() { # $1 = subagent_type, $2 = name
  node -e 'process.stdout.write(JSON.stringify({tool_name:"Agent",tool_input:{team_name:"team-a",subagent_type:process.argv[1],name:process.argv[2],prompt:"Worktree — work ONLY here: /work/wt/r-widget on feat/r-widget."}}))' \
    -- "$1" "$2"
}
# -----------------------------------------------------------------------------------------------

# --- FIRES: the previous baton is still there ---------------------------------------------------------
# Each pair is one step of the pipeline, and the predecessor differs at each step — a single arm would
# not tell a correct mapping from one that always names the same role.
roster team-lead arch-widget:architect
assert_fires "a developer while its architect is on the roster" "$(a developer dev-widget)" 'arch-widget'
roster team-lead dev-widget:developer
assert_fires "a reviewer while its developer is on the roster"  "$(a code-reviewer cr-widget)" 'dev-widget'
roster team-lead planrev-widget:plan-reviewer
assert_fires "an architect while the plan reviewer remains"     "$(a architect arch-widget)" 'planrev-widget'

# --- QUIET: nobody is holding anything -----------------------------------------------------------------
roster team-lead
assert_quiet "only the lead on the roster" "$(a developer dev-widget)"
# The predecessor of a developer is its architect; a planner still running is a different wave's
# business, and reminding about it would train the reader to dismiss the message.
roster team-lead planner-widget:planner
assert_quiet "a role that is not the predecessor" "$(a developer dev-widget)"

# --- QUIET: dispatches with no predecessor in the pipeline ------------------------------------------------
roster team-lead dev-widget:developer
assert_quiet "a general-purpose agent" "$(a general-purpose search-x)"
assert_quiet "not an Agent dispatch" \
  "$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:"ls"}}))')"

# --- QUIET: no roster to read ------------------------------------------------------------------------------
rm -f "$AAL_TMP/teams/team-a/config.json"
assert_quiet "no roster file" "$(a developer dev-widget)"

summary

#!/usr/bin/env bash
# require-root-cause-before-askuser — a question that describes a fault with no diagnosis hands the
# diagnosis to the person least able to run the command. The gate denies such a question unless the
# body carries one measurement and one exclusion, and separately denies a question about the
# production box when no runbook was read in the same session.
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/require-root-cause-before-askuser.mjs

# --- portable activation context ---------------------------------------------------------------
AAL_PROJ="$(mktemp -d)"
mkdir -p "$AAL_PROJ/.claude" "$AAL_PROJ/docs/runbooks"
: > "$AAL_PROJ/.claude/.autoloop"
AAL_PROJ_N="$(aal_native "$AAL_PROJ")"
export CLAUDE_PROJECT_DIR="$AAL_PROJ_N"
trap 'rm -rf "$AAL_PROJ"' EXIT

# Two synthetic transcripts. The runbook limb asks a question about the SESSION's history — "was a
# runbook read this turn" — so a fixture has to supply that history rather than inherit whatever the
# operator happens to have read. One transcript contains a Read of a runbook, the other does not.
NO_RUNBOOK="$AAL_PROJ_N/no-runbook.jsonl"
WITH_RUNBOOK="$AAL_PROJ_N/with-runbook.jsonl"
node -e 'const fs=require("fs");
fs.writeFileSync(process.argv[1], JSON.stringify({message:{content:[{type:"tool_use",name:"Read",input:{file_path:"/work/project/README.md"}}]}})+"\n");
fs.writeFileSync(process.argv[2], JSON.stringify({message:{content:[{type:"tool_use",name:"Read",input:{file_path:"/work/project/docs/runbooks/OPS.md"}}]}})+"\n");
' -- "$AAL_PROJ/no-runbook.jsonl" "$AAL_PROJ/with-runbook.jsonl"
# -----------------------------------------------------------------------------------------------

q() { # $1 = question text, $2 = transcript path (default: the one with no runbook)
  node -e 'process.stdout.write(JSON.stringify({tool_name:"AskUserQuestion",transcript_path:process.argv[2],tool_input:{questions:[{question:process.argv[1],header:"decision",options:[{label:"A",description:"do it"},{label:"B",description:"do not"}]}]}}))' \
    -- "$1" "${2:-$NO_RUNBOOK}"
}

# --- DENY: a fault with no diagnosis behind it -----------------------------------------------------
assert_deny "the suite went red" \
  "$(q "The suite went red after the merge. Do we revert or push on?")" 'no root cause'
assert_deny "a 502 with no reading" \
  "$(q "The detail page returns 502 for some venues. Should we roll back?")" 'no root cause'
assert_deny "a measurement but no exclusion" \
  "$(q "Measured: the suite is red, rc=1 on the second suite. Revert or push on?")" 'missing .*exclusion'
assert_deny "an exclusion but no measurement" \
  "$(q "The board drift is ruled out as the cause of the failure. Revert or push on?")" 'missing .*measurement'

# --- ALLOW: both halves present -----------------------------------------------------------------------
# A measurement says what was seen; an exclusion says what it is NOT. Either alone still leaves the
# reader to do the diagnosis, which is why the gate wants both and this fixture asserts both singly
# above.
assert_allow "a measurement and an exclusion" \
  "$(q "The suite is red: \`bash hooks/tests/run-all.sh\` gives rc=1 at hooks/tests/teeth.sh:42, and a clean checkout is green, so the merge is ruled out. Revert or push on?")"
assert_allow "the ROOT-CAUSE-NA exemption" \
  "$(q "The suite went red. # ROOT-CAUSE-NA: already diagnosed in the card, this asks only which of two fixes you prefer")"

# --- ALLOW: questions that describe no fault -----------------------------------------------------------
assert_allow "a plain preference" \
  "$(q "Do you want the empty state to say 'no venues yet' or 'nothing here yet'?")"
assert_allow "a scheduling question" \
  "$(q "Should the next wave start with the detail page or with the search box?")"

# --- the OTHER limb: a question about the production box ------------------------------------------------
# This one is not about diagnosis at all — it asks whether the operator's own documentation was
# opened before the question was written, because the answer is usually already in there.
assert_deny "a box question with no runbook read" \
  "$(q "Should I restart the systemd unit on the production box?")" 'no runbook was Read'
assert_allow "…the same question after a runbook was read" \
  "$(q "Should I restart the systemd unit on the production box? # ROOT-CAUSE-NA: not a fault, a scheduling choice" "$WITH_RUNBOOK")"

# --- ALLOW: anything that is not a question ---------------------------------------------------------------
assert_allow "no questions array" \
  "$(node -e 'process.stdout.write(JSON.stringify({tool_name:"AskUserQuestion",tool_input:{}}))')"
assert_allow "a Bash command with the same words" \
  "$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:"echo the suite went red"}}))')"

summary

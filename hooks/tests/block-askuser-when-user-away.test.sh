#!/usr/bin/env bash
# block-askuser-when-user-away — a question asked into an empty room stops the session until somebody
# comes back, and the work that did not depend on the answer stops with it. The gate denies the call
# when the transcript shows nobody has spoken recently, and points at the card fields that record the
# question instead.
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/block-askuser-when-user-away.mjs

# --- portable activation context ---------------------------------------------------------------
AAL_PROJ="$(mktemp -d)"
mkdir -p "$AAL_PROJ/.claude"
: > "$AAL_PROJ/.claude/.autoloop"
AAL_PROJ_N="$(aal_native "$AAL_PROJ")"
export CLAUDE_PROJECT_DIR="$AAL_PROJ_N"
trap 'rm -rf "$AAL_PROJ"' EXIT

# The whole predicate is "did a real person type something in the last hour", so the transcript IS
# the fixture. Stamps come off the clock: a hardcoded one crosses the hour boundary on its own and
# turns an allow arm into a deny with nothing in the diff to explain it.
mkline() { # $1 = ISO stamp, $2 = promptSource, $3 = isMeta
  node -e 'process.stdout.write(JSON.stringify({type:"user",promptSource:process.argv[2],isMeta:process.argv[3]==="true",timestamp:process.argv[1],message:{role:"user"}}))' \
    -- "$1" "$2" "$3"
}
RECENT="$(aal_date_rel '-2 minutes' +%Y-%m-%dT%H:%M:%SZ)"
OLD="$(aal_date_rel '-3 hours' +%Y-%m-%dT%H:%M:%SZ)"

T_HERE="$AAL_PROJ/here.jsonl";    mkline "$RECENT" typed  false > "$T_HERE"
T_QUEUED="$AAL_PROJ/queued.jsonl"; mkline "$RECENT" queued false > "$T_QUEUED"
T_AWAY="$AAL_PROJ/away.jsonl";     mkline "$OLD"    typed  false > "$T_AWAY"
T_EMPTY="$AAL_PROJ/empty.jsonl";   : > "$T_EMPTY"
# Lines, but none of them from a person: this is the state where the gate CAN tell and the answer is
# "nobody is here", as opposed to the empty file below, where it can tell nothing at all.
T_ASSISTANT="$AAL_PROJ/assistant.jsonl"
node -e 'process.stdout.write(JSON.stringify({type:"assistant",timestamp:process.argv[1],message:{role:"assistant"}}))' -- "$RECENT" > "$T_ASSISTANT"
# A message the SYSTEM injected carries the same shape as a typed one. Counting it as presence is how
# a cron-driven turn comes to look like somebody sitting at the keyboard.
T_META="$AAL_PROJ/meta.jsonl";     mkline "$RECENT" typed  true  > "$T_META"
# -----------------------------------------------------------------------------------------------

q() { # $1 = transcript path
  node -e 'process.stdout.write(JSON.stringify({tool_name:"AskUserQuestion",transcript_path:process.argv[1],tool_input:{questions:[{question:"Rename the field?",header:"decision",options:[{label:"A",description:"rename"},{label:"B",description:"keep"}]}]}}))' -- "$1"
}

# --- DENY: nobody has spoken inside the window -----------------------------------------------------
assert_deny "the last message is hours old"  "$(q "$T_AWAY")"  'not here right now'
assert_deny "a meta message is not a person" "$(q "$T_META")"  'not here right now'
assert_deny "only assistant turns"           "$(q "$T_ASSISTANT")" 'not here right now'

# --- ALLOW: they are here --------------------------------------------------------------------------
assert_allow "typed two minutes ago"  "$(q "$T_HERE")"
# A queued message was still written by a person; treating only "typed" as presence would deny the
# case where they lined a few instructions up and walked back.
assert_allow "a queued human message" "$(q "$T_QUEUED")"

# --- ALLOW: the gate cannot see a transcript -------------------------------------------------------
# With no path, or a path that is not there, presence is unknowable. Denying on unknown would make
# every session without a transcript unable to ask anything at all.
assert_allow "no transcript path"     "$(node -e 'process.stdout.write(JSON.stringify({tool_name:"AskUserQuestion",tool_input:{questions:[{question:"x"}]}}))')"
assert_allow "a path that does not exist" "$(q "$AAL_PROJ_N/no-such-file.jsonl")"
# An EMPTY file is the same class as a missing one, and it is worth its own arm because the two
# reach the decision by different routes: one fails to open, the other opens and yields nothing. A
# predicate that read "no lines" as "nobody is here" would deny the first question of every fresh
# session, when the transcript has not been written yet.
assert_allow "an empty transcript"        "$(q "$T_EMPTY")"

# --- ALLOW: any other tool -------------------------------------------------------------------------
assert_allow "a Bash command"  "$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",transcript_path:process.argv[1],tool_input:{command:"git status"}}))' -- "$T_AWAY")"
assert_allow "a Write"         "$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Write",transcript_path:process.argv[1],tool_input:{file_path:"/tmp/x.md",content:"x"}}))' -- "$T_AWAY")"

# --- the denial has to carry the age, or the reader cannot tell how stale the room is ----------------
# A gate that only said "they are away" would be re-triggered blind; the number is what tells the
# author whether to record the question or wait a minute.
out="$(q "$T_AWAY" | node "$HOOK" 2>&1)"
if printf '%s' "$out" | grep -qE 'minutes ago'; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  FAILURES+=("AGE: the denial does not say how long ago they spoke (got: $(printf '%s' "$out" | head -c 160))")
fi

summary

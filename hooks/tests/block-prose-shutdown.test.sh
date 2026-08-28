#!/usr/bin/env bash
# block-prose-shutdown — "you can shut down now", written as prose, is delivered and answered and
# changes nothing: the agent stays on the roster, and the send receipt looks the same as a real one.
# The gate denies the prose form and demands the structured message, and it holds TaskStop back until
# a structured request has actually been sent and had time to land.
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/block-prose-shutdown.mjs

# --- portable activation context ---------------------------------------------------------------
AAL_TMP="$(mktemp -d)"
mkdir -p "$AAL_TMP/proj/.claude" "$AAL_TMP/state" "$AAL_TMP/teams/team-a/inboxes"
: > "$AAL_TMP/proj/.claude/.autoloop"
AAL_TMP_N="$(aal_native "$AAL_TMP")"
export CLAUDE_PROJECT_DIR="$AAL_TMP_N/proj"
# The ledger this gate writes and reads is state; pointed at a sandbox so the fixture neither reads
# the operator's pending shutdowns nor records fictional ones into them.
export SHUTDOWN_LEDGER_STATE_DIR="$AAL_TMP_N/state"
trap 'rm -rf "$AAL_TMP"' EXIT

SID=11111111-2222-3333-4444-555555555555
s() { # $1 = message string
  node -e 'process.stdout.write(JSON.stringify({tool_name:"SendMessage",session_id:process.argv[2],tool_input:{to:"dev-widget",message:process.argv[1]}}))' -- "$1" "$SID"
}
obj() { # a structured message
  node -e 'process.stdout.write(JSON.stringify({tool_name:"SendMessage",session_id:process.argv[1],tool_input:{to:"dev-widget",message:{type:"shutdown_request",reason:"the branch is delivered"}}}))' -- "$SID"
}
# -----------------------------------------------------------------------------------------------

# --- DENY: the prose forms ---------------------------------------------------------------------------
assert_deny "naming the protocol in prose" "$(s "Please send yourself a shutdown_request now.")" 'prose-shaped shutdown order'
assert_deny "you can shut down"            "$(s "Thanks — you can shut down now.")"              'prose-shaped shutdown order'
assert_deny "stand down"                   "$(s "All good, stand down.")"                        'prose-shaped shutdown order'
assert_deny "you are done"                 "$(s "You're all done, nothing more for you to do.")" 'prose-shaped shutdown order'

# --- ALLOW: the structured form, which is the one that lands -------------------------------------------
assert_allow "an object message" "$(obj)"
# A JSON string that parses into a typed message is the same thing on the wire.
assert_allow "a serialised object" \
  "$(s '{"type":"shutdown_request","reason":"the branch is delivered"}')"

# --- ALLOW: ordinary messages, and the documented exemption -----------------------------------------------
assert_allow "a delivery summary"  "$(s "Branch feat/r-widget, head 073f2ed, suite green.")"
assert_allow "a correction"        "$(s "The count in your last message was measured on a stale branch.")"
# Discussing the protocol is not issuing it, and the gate has to leave room for that or it becomes
# impossible to explain the rule to anyone.
assert_allow "the exemption token" \
  "$(s "The way to end an agent is a structured shutdown_request. # PROSE-SHUTDOWN-OK: explaining the protocol, not issuing it")"
# The words inside a quoted span are somebody else's sentence being relayed — but only two spellings
# are recognised as quotation: backticks and curly quotes. A straight double quote is not stripped,
# so relaying a sentence the ordinary way is denied. Both directions pinned, because the denial talks
# about issuing a shutdown while the writer was describing one.
assert_allow "the phrase inside backticks" \
  "$(s 'The reviewer wrote `you can shut down now` in its verdict, which is not how it is done.')"
assert_deny "…the same relay in straight quotes" \
  "$(s 'The reviewer wrote "you can shut down now" in its verdict, which is not how it is done.')" 'prose-shaped shutdown order'

# --- TaskStop: held back until a structured request has been sent and has landed ---------------------------
# 🔴 A SEPARATE session id, because this gate WRITES while it judges: every structured message it
# allows above is recorded as a shutdown sent. Reusing the session id would mean the first arm below
# ran against a ledger the allow arms had already filled, and it would deny for the wrong reason —
# measured, and it reads as a gate defect rather than as arm ordering.
TS_SID=77777777-2222-3333-4444-555555555555
ts() { node -e 'process.stdout.write(JSON.stringify({tool_name:"TaskStop",session_id:process.argv[1],tool_input:{task_id:"dev-widget"}}))' -- "$TS_SID"; }
send_structured() {
  node -e 'process.stdout.write(JSON.stringify({tool_name:"SendMessage",session_id:process.argv[1],tool_input:{to:"dev-widget",message:{type:"shutdown_request",reason:"delivered"}}}))' -- "$TS_SID" \
    | node "$HOOK" >/dev/null 2>&1
}
assert_deny "no shutdown was ever sent" "$(ts)" 'no record'
# Sending one through this very gate is what records it — and it is still too early, because the
# criterion is two turn boundaries, not two statements.
send_structured
assert_deny "sent, but no turn has ended yet" "$(ts)" 'turn boundary'

summary

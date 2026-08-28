#!/usr/bin/env bash
# require-measured-ref-claim — "origin equals your HEAD" is true for about a minute and reads as
# true forever; "origin=e121af91 · HEAD=cf8dca7f" cannot go stale without looking stale. The gate
# denies a message that REPEATS a measurement — an absence claim, a number used as an acceptance
# criterion, or a relationship between two refs — with neither the reading beside it nor an
# unverified marker on it.
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/require-measured-ref-claim.mjs

# --- portable activation context ---------------------------------------------------------------
AAL_PROJ="$(mktemp -d)"
mkdir -p "$AAL_PROJ/.claude"
: > "$AAL_PROJ/.claude/.autoloop"
AAL_PROJ_N="$(aal_native "$AAL_PROJ")"
export CLAUDE_PROJECT_DIR="$AAL_PROJ_N"
trap 'rm -rf "$AAL_PROJ"' EXIT

# 🔴 The gate judges the LEAD's messages and stands aside for everyone else, which it decides from
# the lead marker file. Left to the ambient environment that file is the operator's, so every arm
# below would be answered by whether THIS session happens to be the lead — the fixture would still
# print arms, and they would mean something different on each machine. The marker path is the
# library's own seam, so the fixture writes its own and speaks with the session id in it.
export AAL_LEAD_MARKER_FILE="$AAL_PROJ_N/lead-marker"
SID=11111111-2222-3333-4444-555555555555
printf '%s %s %s\n' "$SID" "$AAL_PROJ_N" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$AAL_PROJ/lead-marker"
# -----------------------------------------------------------------------------------------------

m() { # $1 = message text, $2 = tool (default SendMessage)
  node -e 'process.stdout.write(JSON.stringify({tool_name:process.argv[2]||"SendMessage",session_id:process.argv[3],tool_input:{to:"team-lead",message:process.argv[1],prompt:process.argv[1]}}))' \
    -- "$1" "${2:-SendMessage}" "$SID"
}

# --- DENY: an absence claim with nothing behind it -------------------------------------------------
assert_deny "the gate never ran" \
  "$(m "That arm never ran, so the suite cannot be scored green.")" 'REPEATING a measurement'
assert_deny "zero hits" \
  "$(m "The sweep returned zero hits for that identifier.")" 'REPEATING a measurement'
assert_deny "no evidence behind it" \
  "$(m "The claim has no evidence behind it and the card should be closed.")" 'REPEATING a measurement'

# --- DENY: a number doing the work of an acceptance criterion ---------------------------------------
assert_deny "expected to be N" \
  "$(m "The fixture count is expected to be 42 once the port lands.")" 'REPEATING a measurement'
assert_deny "should be N" \
  "$(m "After the rename the number of matches should be 12.")" 'REPEATING a measurement'

# --- DENY: a relationship between two refs, with fewer than two values printed ------------------------
assert_deny "origin equals HEAD, no values" \
  "$(m "I checked and origin equals your HEAD, so nothing will move under you.")" 'without printing the values'
assert_deny "is an ancestor of, with only ONE sha" \
  "$(m "073f2ed is an ancestor of the remote tip, so the push is a fast-forward.")" 'without printing the values'

# --- ALLOW: the measurement printed beside the claim -------------------------------------------------
assert_allow "a command in backticks" \
  "$(m "That arm never ran: \`bash hooks/tests/teeth.sh\` printed 0 exercised for it.")"
assert_allow "an rc= reading" \
  "$(m "The sweep returned zero hits — rc=1 with the control at rc=0.")"
assert_allow "a file:line citation" \
  "$(m "The claim has no evidence behind it; the predicate is at hooks/lib/is-autoloop-lead.mjs:33.")"
assert_allow "the word measured" \
  "$(m "Measured just now: the count should be 12 and it is.")"
# The ref claim's own way out is two SHA-shaped tokens: the assertion then carries the two values it
# is about, and a reader can re-measure without asking the author what they saw.
assert_allow "both refs printed" \
  "$(m "origin=e121af91 · HEAD=cf8dca7f, so origin equals your HEAD right now.")"

# --- ALLOW: the claim marked as not-measured ----------------------------------------------------------
# Saying "I have not run this" is the honest alternative to measuring, and a gate that denied it too
# would leave the author with only two options: measure, or say nothing.
assert_allow "UNVERIFIED"          "$(m "UNVERIFIED: I believe that arm never ran.")"
assert_allow "an explicit hedge"   "$(m "Please judge whether the count should be 12; do not take that from me.")"

# --- ALLOW: messages making no such claim, and tools this gate does not judge --------------------------
assert_allow "an ordinary message" "$(m "The fixture is written and the branch is amended.")"
assert_allow "an Agent dispatch carries the same rule" "$(m "Measured: rc=0 across the suite." Agent)"
assert_allow "a Bash command with the same words" \
  "$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:"echo the gate never ran"}}))')"

# --- ALLOW: a session that is not the lead -------------------------------------------------------------
# The marker names one session; another one making the same claim is not who this gate is for.
assert_allow "the same claim from a different session" \
  "$(node -e 'process.stdout.write(JSON.stringify({tool_name:"SendMessage",session_id:"99999999-8888-7777-6666-555555555555",tool_input:{to:"team-lead",message:"That arm never ran."}}))')"

summary

#!/usr/bin/env bash
# require-knowledge-contribute-on-declaration — a hand-off that describes a discovery and says nothing
# about writing it down leaves the next agent to find the same thing again. This one only NUDGES: it
# emits context, never a denial, because whether a finding is durable is the author's call and "no
# contribution" is a normal outcome.
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/require-knowledge-contribute-on-declaration.mjs

# --- portable activation context ---------------------------------------------------------------
AAL_TMP="$(mktemp -d)"
mkdir -p "$AAL_TMP/.claude"
AAL_TMP_N="$(aal_native "$AAL_TMP")"
trap 'rm -rf "$AAL_TMP"' EXIT

# 🔴 The gate APPENDS a row to a log inside the configuration directory every time it fires. Pointed
# at the default that is the operator's own config, so a fixture that left this unset would write
# into the installation it is testing — several times per run, on every arm.
export CLAUDE_CONFIG_DIR="$AAL_TMP_N/.claude"
# It only judges agent sessions, which is how the lead's own messages stay out of scope.
export CLAUDE_CODE_CHILD_SESSION=1
# -----------------------------------------------------------------------------------------------

m() { # $1 = message, $2 = recipient (default team-lead)
  node -e 'process.stdout.write(JSON.stringify({tool_name:"SendMessage",tool_input:{to:process.argv[2]||"team-lead",message:process.argv[1]}}))' -- "$1" "${2:-team-lead}"
}

# --- FIRES: discovery wording with no declaration ---------------------------------------------------
assert_fires "I discovered that…"  "$(m "I discovered that the matcher only sees the compact spelling.")" 'KNOWLEDGE-CONTRIBUTION nudge'
assert_fires "turns out…"          "$(m "Turns out the transcript fallback reads the operator's own sessions.")" 'KNOWLEDGE-CONTRIBUTION nudge'
assert_fires "root cause was…"     "$(m "The root cause was a sentence splitter cutting inside the file name.")" 'KNOWLEDGE-CONTRIBUTION nudge'
assert_fires "…to main as well"    "$(m "I discovered that the marker escape was corrupted." main)" 'KNOWLEDGE-CONTRIBUTION nudge'

# --- SILENT: the declaration is present, in any of its three shapes ------------------------------------
# Including `none`, which is the whole point: the line records that the question was considered, and a
# nudge that kept firing after an explicit "nothing durable here" would train its reader to ignore it.
assert_silent "committed"  "$(m "I discovered that the matcher was narrow. KNOWLEDGE-CONTRIBUTION: committed ~/.claude/knowledge/developer/matchers.md")"
assert_silent "surfaced"   "$(m "I discovered that the matcher was narrow. KNOWLEDGE-CONTRIBUTION: surfaced — it is in the delivery summary")"
assert_silent "none"       "$(m "I discovered that the matcher was narrow. KNOWLEDGE-CONTRIBUTION: none — specific to this wave")"

# --- SILENT: hand-offs that describe no discovery ------------------------------------------------------
assert_silent "a plain status"     "$(m "The fixture is written and the branch is amended.")"
assert_silent "a question"         "$(m "Do you want the remaining gates in one commit or several?")"

# --- SILENT: outside the scope this gate claims ----------------------------------------------------------
assert_silent "a message to a peer"  "$(m "I discovered that the matcher was narrow." dev-two)"
assert_silent "not a SendMessage" \
  "$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:"echo I discovered that the matcher was narrow"}}))')"

# --- SILENT: the documented waiver --------------------------------------------------------------------------
: > "$AAL_TMP/.claude/.knowledge-contribute-waived"
assert_silent "a fresh waiver file" "$(m "I discovered that the matcher only sees the compact spelling.")"
rm -f "$AAL_TMP/.claude/.knowledge-contribute-waived"

# --- it warns, and it never denies ---------------------------------------------------------------------------
# The distinction is the whole design: this one is advice, and advice that can block would make every
# hand-off a negotiation about whether a finding is durable enough.
out="$(m "I discovered that the matcher only sees the compact spelling." | node "$HOOK" 2>&1)"
if printf '%s' "$out" | grep -qE '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
  FAIL=$((FAIL+1)); FAILURES+=("SOFT-WARN: the nudge came back as a denial")
else
  PASS=$((PASS+1))
fi
# …and the row it appends lands in the sandbox, not in the operator's configuration.
if [ -s "$AAL_TMP/.claude/.knowledge-contribute-warns.log" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("LOG-SINK: nothing was written to the sandbox log, so the seam is not being honoured")
fi

summary

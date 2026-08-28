#!/usr/bin/env bash
# bash-ledger-archive-preflight — one mount that fans a Bash payload out to the ledger gates, so a
# project pays for one process instead of one per gate. What it owes: route to them, forward the
# first denial unchanged, and stay out of the way of everything that is not a ledger command.
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/bash-ledger-archive-preflight.sh

# --- portable activation context ---------------------------------------------------------------
AAL_PROJ="$(mktemp -d)"
mkdir -p "$AAL_PROJ/.claude/reviews"
: > "$AAL_PROJ/.claude/.autoloop"
AAL_PROJ_N="$(aal_native "$AAL_PROJ")"
export CLAUDE_PROJECT_DIR="$AAL_PROJ_N"
trap 'rm -rf "$AAL_PROJ"' EXIT

# Real bytes on disk: the gate behind this dispatcher only fires on a truncation of a file that
# EXISTS, so a fixture that skipped this would test the routing against a gate that never fires.
printf 'existing content\n' > "$AAL_PROJ/.claude/BACKLOG-archive-01.md"
ARCHIVE="$AAL_PROJ_N/.claude/BACKLOG-archive-01.md"
STAMP="$(aal_date_rel '-2 days' +%Y-%m-%dT%H:%M:%SZ)"
# -----------------------------------------------------------------------------------------------

p() { node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:process.argv[1]}}))' -- "$1"; }

# --- DENY: the payload reaches each gate behind the dispatcher ------------------------------------
# Two different sub-gates, so this asserts the fan-out rather than one lucky route.
assert_deny "routed to the truncation gate" \
  "$(p "echo hi > $ARCHIVE")" 'never discard ledger content'
assert_deny "routed to the archive-state gate" \
  "$(p "cat card.md >> $ARCHIVE   # dod-failed-at=$STAMP")" 'CANNOT BE ARCHIVED'

# --- ALLOW: the trigger filter, which is the reason this mount is cheap ----------------------------
# The dispatcher looks for a ledger word before it spends a process on anything. Without these arms
# a widened filter would cost every Bash call in the session and nothing would go red.
assert_allow "a command naming no ledger"  "$(p "git status --porcelain")"
assert_allow "an unrelated redirect"       "$(p "echo hi > $AAL_PROJ_N/notes.md")"

# --- ALLOW: a ledger command that no sub-gate objects to --------------------------------------------
assert_allow "appending to the archive"    "$(p "echo hi >> $ARCHIVE")"
assert_allow "reading the archive"         "$(p "grep -n DoD $ARCHIVE")"
assert_allow "a new archive number"        "$(p "echo hi > $AAL_PROJ_N/.claude/BACKLOG-archive-02.md")"

# --- the dispatcher's own contract: it must not invent a verdict ------------------------------------
# A denial has to arrive VERBATIM from the gate that made it. A dispatcher that summarised, or that
# emitted its own wording, would leave the reader following instructions nobody wrote — so this
# compares the forwarded bytes against the sub-gate's own output for the same payload.
direct="$(p "echo hi > $ARCHIVE" | node "$(cd "$(dirname "$0")/.." && pwd)/block-truncate-existing-ledger.mjs" 2>/dev/null)"
via="$(p "echo hi > $ARCHIVE" | bash "$HOOK" 2>/dev/null)"
if [ -n "$direct" ] && [ "$direct" = "$via" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  FAILURES+=("FORWARDING: the dispatcher's output differs from the gate's own (direct=${#direct}B via=${#via}B)")
fi

summary

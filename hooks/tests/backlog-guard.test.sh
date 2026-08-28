#!/usr/bin/env bash
# backlog-guard — the one mount in front of the board. It fans a write out to the card gates, and it
# closes the route those gates cannot see: a board edited through a SCRIPT rather than through the
# editing tools, where every one of them is bypassed and the result looks identical.
source "$(dirname "$0")/_lib.sh"
HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$HOOKS_DIR/backlog-guard.mjs"

# --- portable activation context ---------------------------------------------------------------
AAL_TMP="$(mktemp -d)"
mkdir -p "$AAL_TMP/proj/.claude" "$AAL_TMP/delegates"
: > "$AAL_TMP/proj/.claude/.autoloop"
AAL_TMP_N="$(aal_native "$AAL_TMP")"
export CLAUDE_PROJECT_DIR="$AAL_TMP_N/proj"
trap 'rm -rf "$AAL_TMP"' EXIT

# 🔴 The delegate list and the directory it is read from are BOTH seams, and using them is what makes
# this fixture about the DISPATCHER rather than about fifteen other gates. The stand-ins below are two
# lines each: one that always denies and one that never does. With the real list, a failure here could
# mean any of fifteen predicates changed, and the message would not say which.
export BG_HOOKS_DIR="$AAL_TMP_N/delegates"
cat > "$AAL_TMP/delegates/always-deny.mjs" <<'D'
process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: 'STAND-IN DENIAL: the delegate spoke' } }));
D
cat > "$AAL_TMP/delegates/never-deny.mjs" <<'D'
process.stdout.write('{}');
D

BOARD_NAME="$(printf '%s%s' 'BACK' 'LOG.md')"
BOARD="$AAL_TMP_N/proj/.claude/$BOARD_NAME"
printf '%s\n' '# board' > "$AAL_TMP/proj/.claude/$BOARD_NAME"

w() { node -e 'process.stdout.write(JSON.stringify({tool_name:"Write",session_id:"s",tool_input:{file_path:process.argv[1],content:process.argv[2]}}))' -- "$1" "$2"; }
b() { node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",session_id:"s",tool_input:{command:process.argv[1]}}))' -- "$1"; }
# -----------------------------------------------------------------------------------------------

# --- the fan-out: a delegate's denial is what comes back ---------------------------------------------
BG_DELEGATES=always-deny.mjs assert_deny "a board write reaches the delegates" \
  "$(w "$BOARD" 'anything')" 'STAND-IN DENIAL'
# …and with a delegate that has no objection, the write goes through.
BG_DELEGATES=never-deny.mjs assert_allow "a delegate with nothing to say" "$(w "$BOARD" 'anything')"
# The first denial is the answer: a second delegate does not get to overwrite it, because a reader
# needs one instruction rather than a pile.
BG_DELEGATES=always-deny.mjs,never-deny.mjs assert_deny "the first denial wins" \
  "$(w "$BOARD" 'anything')" 'STAND-IN DENIAL'

# --- files that are not the board ----------------------------------------------------------------------
BG_DELEGATES=always-deny.mjs assert_allow "a plan document" "$(w "$AAL_TMP_N/proj/docs/R-widget-plan.md" 'anything')"
BG_DELEGATES=always-deny.mjs assert_allow "a source file"   "$(w "$AAL_TMP_N/proj/src/widget.ts" 'anything')"

# --- 🔴 the route the card gates cannot see ---------------------------------------------------------------
# A script that appends to the board bypasses every gate mounted on the editing tools, and the result
# on disk is identical. The guard reads the SCRIPT the command names and judges its contents.
cat > "$AAL_TMP/writer.mjs" <<'W'
import { appendFileSync } from 'node:fs';
appendFileSync(process.argv[2], 'a card written by a script\n');
W
BG_DELEGATES=always-deny.mjs assert_deny "a script that writes the board" \
  "$(b "node $AAL_TMP_N/writer.mjs $BOARD")" 'STAND-IN DENIAL'
# A redirect is the same route with fewer moving parts.
BG_DELEGATES=always-deny.mjs assert_deny "a shell redirect into the board" \
  "$(b "echo a card >> $BOARD")" 'STAND-IN DENIAL'
# An ordinary command that touches nothing of the kind is left alone.
BG_DELEGATES=always-deny.mjs assert_allow "an unrelated command" "$(b "git status --porcelain")"

# --- a delegate that is not there is skipped, not fatal ------------------------------------------------------
# A missing entry has to leave the mount working: treating it as an error takes the whole board guard
# down for everyone, and treating it as a denial would be worse.
BG_DELEGATES=no-such-delegate.mjs,never-deny.mjs assert_allow "a missing delegate" "$(w "$BOARD" 'anything')"
BG_DELEGATES=no-such-delegate.mjs,always-deny.mjs assert_deny "…and the rest still run" \
  "$(w "$BOARD" 'anything')" 'STAND-IN DENIAL'

summary

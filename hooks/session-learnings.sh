#!/usr/bin/env bash
# Stop hook: session-learnings — turn-end reflect/record.
#
# At each natural turn-end this re-injects the "learning / remind / record" step via
# decision:block, so the model reviews the session for user corrections (-> save as a
# feedback memory) and logs any struggles to the project .claude/struggle-log.md before
# stopping.
#
# LOOP GUARD (REQUIRED): a Stop hook that returns decision:block re-fires after the model
# acts on it. We read `stop_hook_active` from stdin and exit 0 the moment it is already
# true, so the block fires EXACTLY ONCE per turn (Claude also force-stops after 8
# consecutive blocks). Without this guard the session can never end. parse-json.sh's
# json_get returns 'true' for boolean true, '' otherwise.
#
# THROTTLE: the backstop reflection only needs to fire PERIODICALLY, not on every turn-end.
# A long autoloop wave yields dozens of times (every teammate message is a turn-end), so an
# un-throttled block = dozens of redundant reflection cycles. After the loop guard we skip
# (exit 0, allow stop) when the last fire for THIS session was < WINDOW ago. Window is
# per-session (keyed by session_id) and tunable via SESSION_LEARNINGS_THROTTLE_SECS
# (default 900 = 15 min).

set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":pipeline-roles:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0

source "$(dirname "$0")/lib/parse-json.sh"
aal_have_node || exit 0

# Drain stdin (the Stop hook JSON payload).
INPUT=$(cat)

# --- Loop guard: if we already blocked once this turn, let the model stop. ---
STOP_ACTIVE=$(json_get "$INPUT" stop_hook_active)
[ "$STOP_ACTIVE" = "true" ] && exit 0

# --- Throttle: fire at most once per WINDOW per session. ---
WINDOW="${SESSION_LEARNINGS_THROTTLE_SECS:-900}"
SESSION_ID=$(json_get "$INPUT" session_id)
STATE_DIR="${CLAUDE_PLUGIN_DATA:-${TMPDIR:-/tmp}}/aal-state"
mkdir -p "$STATE_DIR" 2>/dev/null || true
STATE_FILE="$STATE_DIR/session-learnings-${SESSION_ID:-global}.last"
NOW=$(date +%s)
if [ -f "$STATE_FILE" ]; then
  LAST=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
  case "$LAST" in (*[!0-9]*|'') LAST=0 ;; esac
  if [ $((NOW - LAST)) -lt "$WINDOW" ]; then
    exit 0   # within throttle window — let the model stop quietly
  fi
fi
echo "$NOW" > "$STATE_FILE" 2>/dev/null || true
# Best-effort prune of stale per-session state (older than 2 days).
find "$STATE_DIR" -name 'session-learnings-*.last' -mtime +2 -delete 2>/dev/null || true

# --- Emit the turn-end learning/record directive (decision:block + reason). ---
# Single-quoted heredoc: literal, no shell interpolation, double quotes safe.
cat <<'EOF'
{"decision":"block","reason":"Quiet session-learnings check. Default is SKIP. Did this session produce EITHER (a) a NEW durable fact about the user, the project, a confirmed preference/feedback, or an external reference that is not already saved, OR (b) an execution struggle / mistake / harness-friction (malformed tool call, mis-sequencing, tooling slip)? If neither (the common case): stop immediately with NO commentary about this check. If yes, ROUTE by type: a durable user/project/feedback/reference fact -> exactly ONE memory note (save only genuinely reusable facts; fold into an existing note if one fits); an execution struggle / mistake / harness-friction -> exactly ONE line in .claude/struggle-log.md, NOT a memory. Then stop. Do not narrate the check, do not re-read memories to verify, do not re-explain finished work.","systemMessage":"session-learnings: quiet check","suppressOutput":true}
EOF

exit 0

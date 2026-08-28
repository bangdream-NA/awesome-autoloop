#!/usr/bin/env bash

set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":pipeline-roles:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0

source "$(dirname "$0")/lib/parse-json.sh"
aal_have_node || exit 0

INPUT=$(cat)

STOP_ACTIVE=$(json_get "$INPUT" stop_hook_active)
[ "$STOP_ACTIVE" = "true" ] && exit 0

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
    exit 0
  fi
fi
echo "$NOW" > "$STATE_FILE" 2>/dev/null || true
find "$STATE_DIR" -name 'session-learnings-*.last' -mtime +2 -delete 2>/dev/null || true

cat <<'EOF'
{"decision":"block","reason":"Quiet session-learnings check. Default is SKIP. Did this session produce EITHER (a) a NEW durable fact about the user, the project, a confirmed preference/feedback, or an external reference that is not already saved, OR (b) an execution struggle / mistake / harness-friction (malformed tool call, mis-sequencing, tooling slip)? If neither (the common case): stop immediately with NO commentary about this check. If yes, ROUTE by type: a durable user/project/feedback/reference fact -> exactly ONE memory note (save only genuinely reusable facts; fold into an existing note if one fits); an execution struggle / mistake / harness-friction -> exactly ONE line in .claude/struggle-log.md, NOT a memory. Then stop. Do not narrate the check, do not re-read memories to verify, do not re-explain finished work.","systemMessage":"session-learnings: quiet check","suppressOutput":true}
EOF

exit 0

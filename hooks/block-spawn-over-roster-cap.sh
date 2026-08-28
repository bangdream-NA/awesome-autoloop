#!/usr/bin/env bash
set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":pipeline-roles:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
source "$(dirname "$0")/lib/parse-json.sh"
aal_have_node || exit 0
INPUT=$(cat)
TOOL=$(json_get "$INPUT" tool_name)
[ "$TOOL" = "Agent" ] || exit 0

CAP="${AAL_ROSTER_CAP:-16}"
TEAMS_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/teams"
[ -d "$TEAMS_DIR" ] || exit 0

TEAM_NAME=$(json_get "$INPUT" team_name)
find "$TEAMS_DIR" -maxdepth 1 -type d -mtime +2 2>/dev/null | while IFS= read -r d; do
  [ "$d" = "$TEAMS_DIR" ] && continue
  [ -n "$TEAM_NAME" ] && [ "$(basename "$d")" = "$TEAM_NAME" ] && continue
  rm -rf "$d" 2>/dev/null || true
done

[ -z "$TEAM_NAME" ] && exit 0
N=0; BIG="$TEAM_NAME"
if [ -f "$TEAMS_DIR/$TEAM_NAME/config.json" ]; then
  N=$(node -e 'try{const j=require(process.argv[1]);console.log((j.members||[]).length)}catch(e){console.log(0)}' "$TEAMS_DIR/$TEAM_NAME/config.json" 2>/dev/null)
  case "$N" in (*[!0-9]*|'') N=0 ;; esac
fi

if [ "$N" -ge "$CAP" ]; then
  cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED spawn: team '${BIG}' live roster = ${N} (cap ${CAP}). shutdown-on-accept ENFORCED — before spawning a NEW teammate, shut down a done/idle one (SendMessage shutdown_request to any whose deliverable is accepted: merged PR / APPROVED review / handed-off spec). config.json members PRUNES on shutdown, so killing a done agent frees the slot. Do NOT reuse an existing agent instead — that mixes context. Then re-spawn."}}
EOF
  exit 0
fi
exit 0

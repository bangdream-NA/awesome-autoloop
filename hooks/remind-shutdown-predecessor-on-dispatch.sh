#!/usr/bin/env bash
set -euo pipefail

case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":pipeline-roles:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
source "$(dirname "$0")/lib/team-roster.sh"

TEAMS_DIR="${TEAM_ROSTER_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/teams}"
PAYLOAD=$(cat)

TOOL=$(printf '%s' "$PAYLOAD" | node -e "let s='';process.stdin.on('data',c=>s+=c);process.stdin.on('end',()=>{try{process.stdout.write(JSON.parse(s).tool_name||'')}catch{}});" 2>/dev/null || echo "")
[ "$TOOL" = "Agent" ] || exit 0

DISPATCHED=$(printf '%s' "$PAYLOAD" | node -e "let s='';process.stdin.on('data',c=>s+=c);process.stdin.on('end',()=>{try{const o=JSON.parse(s);process.stdout.write(String((o.tool_input&&o.tool_input.subagent_type)||''))}catch{}});" 2>/dev/null || echo "")
case "$DISPATCHED" in
  plan-reviewer)  PRED="planner" ;;
  uiux-designer)  PRED="plan-reviewer" ;;
  architect)      PRED="plan-reviewer" ;;
  developer)      PRED="architect" ;;
  code-reviewer)  PRED="developer" ;;
  planner)        PRED="plan-reviewer" ;;
  *)              exit 0 ;;
esac

CFG=$(team_roster_cfg "$PAYLOAD" "$TEAMS_DIR")
[ -n "$CFG" ] && [ -f "$CFG" ] || exit 0

PROMPT=$(printf '%s' "$PAYLOAD" | node -e "let s='';process.stdin.on('data',c=>s+=c);process.stdin.on('end',()=>{try{const o=JSON.parse(s);process.stdout.write(String((o.tool_input&&o.tool_input.prompt)||''))}catch{}});" 2>/dev/null || echo "")
STALE=$(node "$(dirname "$0")/lib/roster-members-of-type.mjs" "$CFG" "$PRED" "$PROMPT" 2>/dev/null || echo "")
[ -n "$STALE" ] || exit 0

NAME=$(printf '%s' "$PAYLOAD" | node -e "let s='';process.stdin.on('data',c=>s+=c);process.stdin.on('end',()=>{try{const o=JSON.parse(s);process.stdout.write(String((o.tool_input&&o.tool_input.name)||''))}catch{}});" 2>/dev/null || echo "")

node "$(dirname "$0")/lib/shutdown-predecessor-message.mjs" "$DISPATCHED" "$NAME" "$PRED" "$STALE"
exit 0

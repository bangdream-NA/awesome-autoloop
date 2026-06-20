#!/usr/bin/env bash
# PreToolUse hook on Agent: BLOCK bare Agent calls without explicit team_name
# ONLY checks tool_input for team_name — filesystem fallback was too permissive

set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":pipeline-roles:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
source "$(dirname "$0")/lib/parse-json.sh"
source "$(dirname "$0")/lib/log-denial.sh"

if ! aal_have_node; then
  cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: awesome-autoloop requires node on PATH to evaluate this gate, and node was not found. Install node >=18, or disable the plugin / remove this gate group from AAL_GATES. (Fail-closed: a security gate that can't evaluate must not silently allow.)"}}
JSON
  exit 0
fi

INPUT=$(cat)

# Require explicit non-empty team_name in the Agent tool input — no fallbacks.
# Use json_get so `team_name:""` (empty string) is correctly treated as missing.
TEAM=$(json_get "$INPUT" team_name)

if [ -z "$TEAM" ]; then
  # Auto-log to struggle log. Resolve project dir via env / git root / home — never
  # hardcode a project default.
  DATE=$(date +%Y-%m-%d)
  PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || echo "")}"
  STRUGGLE_LOG=""
  if [ -n "$PROJECT_DIR" ] && [ -d "$PROJECT_DIR/.claude" ]; then
    STRUGGLE_LOG="$PROJECT_DIR/.claude/struggle-log.md"
  else
    STRUGGLE_LOG="$HOME/.claude/struggle-log.md"
  fi
  [ -f "$STRUGGLE_LOG" ] && echo "| $DATE | team-lead | Agent spawn | Bare Agent call blocked by PreToolUse hook | No team_name in tool_input | Auto-blocked |" >> "$STRUGGLE_LOG" 2>/dev/null || true
  aal_log_denial "block-bare-agent" "bare-agent-no-team" "Agent spawn without team_name"

  cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: All agent work must go through a team. Pass team_name + subagent_type:\n\nAgent({\n  team_name: '<existing-team>',\n  subagent_type: 'planner' | 'plan-reviewer' | 'architect' | 'developer' | 'code-reviewer' | 'uiux-designer'  // pipeline\n              | 'Explore' | 'general-purpose'                                                                  // ad-hoc research (read-only or broad)\n  name: '<role-name>',\n  description: '<5-word task>',\n  prompt: '<full brief>'\n})\n\nPass a team_name string (any value) — there is no separate TeamCreate step (TeamCreate was removed in Claude Code v2.1.178; an implicit team is created per session). Explore + general-purpose are valid for read-only research / broad searches when no pipeline-role fits."}}
EOF
  exit 0
fi

# Pipeline roles must be REAL roster teammates (with the SendMessage/TaskUpdate mailbox),
# NOT anonymous one-shot sub-agents. A dispatch with team_name but NO `name` spawns
# mailbox-less (delivers via task-notification, never joins the roster); run_in_background:true
# likewise makes a one-shot bg sub-agent, not a persistent teammate. Either = a bare
# sub-agent in disguise (team_name alone is necessary, NOT sufficient).
STYPE=$(json_get "$INPUT" subagent_type)
NAME=$(json_get "$INPUT" name)
BG=$(echo "$INPUT" | grep -oE '"run_in_background"[[:space:]]*:[[:space:]]*true' || true)
case "$STYPE" in
  planner|plan-reviewer|architect|developer|code-reviewer|uiux-designer|designer)
    if [ -z "$NAME" ] || [ -n "$BG" ]; then
      cat <<EOF2
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: pipeline role '$STYPE' must be a REAL roster teammate: pass a non-empty name AND do NOT set run_in_background:true. team_name alone (or run_in_background:true) spawns an anonymous one-shot sub-agent WITHOUT the SendMessage/TaskUpdate mailbox (it delivers via task-notification and never joins the team roster) = a bare sub-agent in disguise. Re-dispatch as: Agent({team_name, subagent_type:'$STYPE', name:'<role>-<wave>', prompt}). Read-only research types (Explore/general-purpose) are exempt from the name requirement."}}
EOF2
      exit 0
    fi
    ;;
esac

exit 0

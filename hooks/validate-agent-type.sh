#!/usr/bin/env bash
# PreToolUse hook on Agent: BLOCK wrong agent types in team context
# Also auto-logs violations to struggle-log.md

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
AGENT_TYPE=$(json_get "$INPUT" subagent_type)
TEAM_NAME=$(json_get "$INPUT" team_name)

# Only validate when a team context exists
if [ -z "$TEAM_NAME" ]; then
  exit 0
fi

# Pipeline agents (the 5-agent contract from CLAUDE.md).
# Also allow Explore (read-only search) + general-purpose (broad research) since
# they don't violate the pipeline — they just don't ADVANCE it.
ALLOWED_TYPES="planner plan-reviewer architect developer code-reviewer uiux-designer Explore general-purpose"

if [ -n "$AGENT_TYPE" ]; then
  for allowed in $ALLOWED_TYPES; do
    if [ "$AGENT_TYPE" = "$allowed" ]; then
      exit 0
    fi
  done

  # Resolve project dir (main repo from worktree)
  DATE=$(date +%Y-%m-%d)
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    PROJECT_DIR="$CLAUDE_PROJECT_DIR"
  else
    COMMON_DIR=$(git rev-parse --git-common-dir 2>/dev/null || echo "")
    if [ -n "$COMMON_DIR" ]; then
      case "$COMMON_DIR" in
        /*|[A-Za-z]:*) ;;
        *) COMMON_DIR="$(pwd)/$COMMON_DIR" ;;
      esac
      case "$COMMON_DIR" in
        */.git) PROJECT_DIR="${COMMON_DIR%/.git}" ;;
        *) PROJECT_DIR=$(dirname "$COMMON_DIR") ;;
      esac
    else
      PROJECT_DIR="$HOME"
    fi
  fi
  STRUGGLE_LOG="$PROJECT_DIR/.claude/struggle-log.md"
  [ -f "$STRUGGLE_LOG" ] && echo "| $DATE | team-lead | Agent spawn | Used '$AGENT_TYPE' instead of pipeline agent | PreToolUse hook blocked it | Auto-logged by hook |" >> "$STRUGGLE_LOG" 2>/dev/null || true
  aal_log_denial "validate-agent-type" "agent-type-not-allowed" "subagent_type '$AGENT_TYPE' not in allowed set"

  cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: subagent_type '$AGENT_TYPE' is not in allowed list. Use one of: $ALLOWED_TYPES. (Pipeline: planner/architect/developer/code-reviewer/uiux-designer; ad-hoc research: Explore/general-purpose.)"}}
EOF
  exit 0
fi

exit 0

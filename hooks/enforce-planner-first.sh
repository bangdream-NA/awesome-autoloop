#!/usr/bin/env bash

set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":pipeline-roles:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
source "$(dirname "$0")/lib/log-denial.sh"
aal_is_autoloop_project || exit 0

INPUT=$(cat)

AGENT_TYPE=$(echo "$INPUT" | grep -o '"subagent_type"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"subagent_type"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || echo "")
TEAM_NAME=$(echo "$INPUT" | grep -o '"team_name"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"team_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || echo "")

if [ "$AGENT_TYPE" != "developer" ] || [ -z "$TEAM_NAME" ]; then
  exit 0
fi

if echo "$TEAM_NAME" | grep -qiE 'fix|bug|hotfix|patch'; then
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || echo "")}"
SPECS_DIR="$PROJECT_DIR/docs/product-specs"

if [ -z "$PROJECT_DIR" ] || [ ! -d "$SPECS_DIR" ]; then
  cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: No spec found in docs/product-specs/. For feature work, dispatch planner first to create a spec before developer. Bug fixes can use team names containing 'fix' or 'bug' to skip this check."}}
EOF
  exit 0
fi

RECENT_SPEC=$(find "$SPECS_DIR" -name "*.md" -mmin -30 2>/dev/null | head -1 || true)

if [ -z "$RECENT_SPEC" ]; then
  TEAM_CONFIG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/teams/$TEAM_NAME/config.json"
  if [ -f "$TEAM_CONFIG" ] && grep -q '"planner"' "$TEAM_CONFIG" 2>/dev/null; then
    exit 0
  fi

  DATE=$(date +%Y-%m-%d)
  STRUGGLE_LOG="$PROJECT_DIR/.claude/struggle-log.md"
  if [ -f "$STRUGGLE_LOG" ]; then
    echo "| $DATE | team-lead | Developer spawn | Attempted developer spawn without planner spec | No recent spec in docs/product-specs/ | Auto-blocked |" >> "$STRUGGLE_LOG" 2>/dev/null || true
  fi
  aal_log_denial "enforce-planner-first" "developer-no-spec" "Developer spawn without a recent spec"

  cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: No recent spec found. For feature work, dispatch planner first to write spec to docs/product-specs/. Bug fix teams (name contains 'fix'/'bug') skip this check."}}
EOF
  exit 0
fi

exit 0

#!/usr/bin/env bash
# PreToolUse hook on Write/Edit: BLOCK the team lead from editing app/ source code
# The team lead should only edit harness files (.claude/, docs/, CLAUDE.md, AGENTS.md);
# app source code must be edited by developer agents only.
#
# NODE-FREE: pure grep/sed. The group-case + activation guard precede everything, so a
# non-autoloop / deselected-group call no-ops before any work. No node-guard (no JSON-lib
# dependency — file_path is extracted by grep/sed directly).

set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":pipeline-roles:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0

INPUT=$(cat)

FILE_PATH=$(echo "$INPUT" | grep -o '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || echo "")

# Allow if not editing a file (shouldn't happen but safety check)
if [ -z "$FILE_PATH" ]; then
  exit 0
fi

# Allow harness files: .claude/, docs/, CLAUDE.md, AGENTS.md, settings, hooks, memory, plans
if echo "$FILE_PATH" | grep -qiE '\.claude/|/docs/|CLAUDE\.md|AGENTS\.md|settings\.json|/hooks/|/memory/|/plans/|/commands/|/agents/|/skills/|/rules/'; then
  exit 0
fi

# Block app source-code edits. The set of source-tree path patterns is overridable via
# AAL_APP_SRC_GLOBS (colon-separated regex alternatives). Default = a generic source-tree
# heuristic that matches a leading `src/`, `app/`, `apps/`, `lib/`, `packages/`, `pkg/`,
# `internal/`, or `cmd/` segment.
APP_SRC_RE="${AAL_APP_SRC_GLOBS:-(^|/)(src|app|apps|lib|packages|pkg|internal|cmd)/}"
if echo "$FILE_PATH" | grep -qiE "$APP_SRC_RE"; then
  DATE=$(date +%Y-%m-%d)
  PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)}"
  STRUGGLE_LOG="$PROJECT_DIR/.claude/struggle-log.md"
  if [ -f "$STRUGGLE_LOG" ]; then
    echo "| $DATE | team-lead | Edit source | Attempted to edit app source directly: $FILE_PATH | Team lead should dispatch developer agent | Auto-blocked |" >> "$STRUGGLE_LOG" 2>/dev/null || true
  fi

  cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: Team lead cannot edit app source code directly. Dispatch a developer agent to make this change. File: $FILE_PATH"}}
EOF
  exit 0
fi

exit 0

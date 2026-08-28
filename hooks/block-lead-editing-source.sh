#!/usr/bin/env bash
# NODE-FREE: pure grep/sed. The group-case + activation guard precede everything, so a

set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":pipeline-roles:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0

INPUT=$(cat)

FILE_PATH=$(echo "$INPUT" | grep -o '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || echo "")


# Windows tool payloads carry backslash separators (`Z:\\repo\\apps\\web\\page.tsx`), and every
# predicate below is written with `/`. Without this the gate silently allows exactly the edits it
# exists to stop, on the one platform where nothing else notices — the deny simply never fires.
FILE_PATH="${FILE_PATH//\\//}"
if [ -z "$FILE_PATH" ]; then
  exit 0
fi

if echo "$FILE_PATH" | grep -qiE '\.claude/|/docs/|CLAUDE\.md|AGENTS\.md|settings\.json|/hooks/|/memory/|/plans/|/commands/|/agents/|/skills/|/rules/'; then
  exit 0
fi

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

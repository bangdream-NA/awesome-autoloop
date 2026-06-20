#!/usr/bin/env bash
# PreToolUse/Bash: HARD BLOCK git commit/push if .claude/ is staged
set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":commit-hygiene:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0

source "$(dirname "$0")/lib/parse-json.sh"

if ! aal_have_node; then
  cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: awesome-autoloop requires node on PATH to evaluate this gate, and node was not found. Install node >=18, or disable the plugin / remove this gate group from AAL_GATES. (Fail-closed: a security gate that can't evaluate must not silently allow.)"}}
JSON
  exit 0
fi

INPUT=$(cat)
COMMAND=$(json_get "$INPUT" command)

# Only check git commit and git push
echo "$COMMAND" | grep -qE 'git (commit|push)' || exit 0

# Honor a leading `cd <dir> &&` so a worktree workflow resolves the right repo
# (the hook is spawned with the parent shell's start cwd, NOT the cwd implied by
# `cd <project> && git commit`). Mirrors require-review-before-ship.sh:53.
LEADING_CD_DIR=$(aal_extract_cd_target "$COMMAND")
if [ -n "$LEADING_CD_DIR" ] && [ -d "$LEADING_CD_DIR" ]; then
  cd "$LEADING_CD_DIR" 2>/dev/null || true
elif [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
  cd "$CLAUDE_PROJECT_DIR" 2>/dev/null || true
fi

# Check for .claude/ in staged files
if git diff --cached --name-only 2>/dev/null | grep -q '^\.claude/'; then
  cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: .claude/ directory is staged. Run: git reset HEAD .claude/ — NEVER push .claude/ to GitHub."}}
EOF
  exit 0
fi

exit 0

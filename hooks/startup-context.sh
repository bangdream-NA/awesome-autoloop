#!/usr/bin/env bash
# startup-context.sh — UserPromptSubmit hook: inject project git-state context on the first prompt
# of a session (branch / last commit / uncommitted count). Runs once per session via a flag file.
set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":pipeline-roles:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0

# Cross-platform per-session flag dir (mirrors loop-detection's state-dir resolution).
STATE_DIR="${CLAUDE_PLUGIN_DATA:-${XDG_STATE_HOME:-$HOME/.local/state}}/aal-state"
mkdir -p "$STATE_DIR" 2>/dev/null || true
FLAG_FILE="$STATE_DIR/startup-context-done"

# Skip if already injected this session.
if [ -f "$FLAG_FILE" ]; then
  exit 0
fi

# Create flag (clean up after 2 hours).
touch "$FLAG_FILE" 2>/dev/null || true
(sleep 7200 && rm -f "$FLAG_FILE") >/dev/null 2>&1 &

# Gather project state.
PROJECT_DIR="$(aal_resolve_project_dir)"
if [ -d "$PROJECT_DIR/.git" ]; then
  BRANCH=$(git -C "$PROJECT_DIR" branch --show-current 2>/dev/null || echo "unknown")
  LAST_COMMIT=$(git -C "$PROJECT_DIR" log -1 --format="%h %s" 2>/dev/null || echo "unknown")
  CHANGED=$(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null | wc -l | tr -d ' ' || echo "0")
  echo "Project state: branch=$BRANCH, last commit=$LAST_COMMIT, uncommitted changes: $CHANGED files"
fi

exit 0

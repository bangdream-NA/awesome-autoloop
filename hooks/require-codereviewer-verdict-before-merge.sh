#!/usr/bin/env bash
set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":merge-gates:"*) ;; *) exit 0 ;; esac
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
echo "$COMMAND" | grep -qE '\bgh[[:space:]]+pr[[:space:]]+merge\b' || exit 0

HOOK_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
LEADING_CD_DIR=$(aal_extract_cd_target "$COMMAND")
if [ -n "$LEADING_CD_DIR" ] && [ -d "$LEADING_CD_DIR" ]; then HOOK_PROJECT_DIR="$LEADING_CD_DIR"; fi
cd "$HOOK_PROJECT_DIR" 2>/dev/null || true

PR_NUM=$(echo "$COMMAND" | grep -oE 'gh[[:space:]]+pr[[:space:]]+merge[[:space:]]+[0-9]+' | grep -oE '[0-9]+$' || echo "")
if [ -z "$PR_NUM" ]; then PR_NUM=$(gh pr view --json number --jq .number 2>/dev/null || echo ""); fi

deny() {
  cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED merge of PR #${PR_NUM:-?}: $1"}}
EOF
  exit 0
}

[ -z "$PR_NUM" ] && exit 0

PROJECT_DIR="$HOOK_PROJECT_DIR"
COMMON_DIR=$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")
case "$COMMON_DIR" in
  */.git/worktrees/*) MAIN_GIT="${COMMON_DIR%/worktrees/*}"; PROJECT_DIR="${MAIN_GIT%/.git}" ;;
esac

PV=$(ls "$PROJECT_DIR/.claude/reviews/pr${PR_NUM}-r"*.md 2>/dev/null | sort -V | tail -1 || true)
if [ -n "$PV" ] && [ -f "$PV" ]; then
  LATEST_BLOCK=$(cat "$PV")
else
  REVIEW_FILE="$PROJECT_DIR/.claude/code-reviews.md"
  [ ! -f "$REVIEW_FILE" ] && deny "no .claude/reviews/pr${PR_NUM}-r*.md or code-reviews.md — dispatch a FRESH code-reviewer (Mode B) first"

  LAST_BLOCK_LINE=$(grep -nE "^## PR #${PR_NUM}\b" "$REVIEW_FILE" | tail -1 | cut -d: -f1 || echo "")
  [ -z "$LAST_BLOCK_LINE" ] && deny "no review entry for this PR in code-reviews.md — dispatch a FRESH code-reviewer"

  NEXT_HEADER_LINE=$(awk -v start="$LAST_BLOCK_LINE" 'NR > start && /^## / { print NR; exit }' "$REVIEW_FILE")
  if [ -z "$NEXT_HEADER_LINE" ]; then
    LATEST_BLOCK=$(sed -n "${LAST_BLOCK_LINE},\$p" "$REVIEW_FILE")
  else
    END_LINE=$((NEXT_HEADER_LINE - 1))
    LATEST_BLOCK=$(sed -n "${LAST_BLOCK_LINE},${END_LINE}p" "$REVIEW_FILE")
  fi
fi

if ! echo "$LATEST_BLOCK" | grep -qiE 'Reviewer-type:[[:space:]]*code-reviewer'; then
  deny "the ## PR #${PR_NUM} review block has NO 'Reviewer-type: code-reviewer' attestation. Mode-B review must be authored by a FRESH code-reviewer agent (subagent_type=code-reviewer), never an architect/planner/developer, and never a reused agent that touched the wave. Re-review with a fresh code-reviewer whose verdict includes the line 'Reviewer-type: code-reviewer'."
fi
exit 0

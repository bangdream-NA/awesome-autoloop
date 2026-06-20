#!/usr/bin/env bash
# post-merge-cleanup-reminder.sh
# PostToolUse hook (matcher: Bash)
# After a successful `gh pr merge`, remind the team-lead to:
#   1. Update the task board (BACKLOG.md — the single source of truth)
#   2. Remove this wave's worktrees
#   3. Delete local + remote branches
#   4. Make a doc-sync decision

set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":pipeline-roles:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
source "$(dirname "$0")/lib/parse-json.sh"
aal_have_node || exit 0

PAYLOAD=$(cat)

TOOL=$(printf '%s' "$PAYLOAD" | node -e "let s=''; process.stdin.on('data',c=>s+=c); process.stdin.on('end',()=>{try{const o=JSON.parse(s);process.stdout.write(o.tool_name||'')}catch{}});" 2>/dev/null || echo "")
if [ "$TOOL" != "Bash" ]; then
  exit 0
fi

CMD=$(printf '%s' "$PAYLOAD" | node -e "let s=''; process.stdin.on('data',c=>s+=c); process.stdin.on('end',()=>{try{const o=JSON.parse(s);process.stdout.write((o.tool_input&&o.tool_input.command)||'')}catch{}});" 2>/dev/null || echo "")

RESPONSE=$(printf '%s' "$PAYLOAD" | node -e "let s=''; process.stdin.on('data',c=>s+=c); process.stdin.on('end',()=>{try{const o=JSON.parse(s);const r=o.tool_response;process.stdout.write(typeof r==='string'?r:JSON.stringify(r)||'')}catch{}});" 2>/dev/null || echo "")

# Only fire on successful gh pr merge
IS_MERGE=$(printf '%s' "$CMD" | grep -cE '\bgh[[:space:]]+pr[[:space:]]+merge\b' || true)
if [ "$IS_MERGE" = "0" ]; then
  exit 0
fi

# Check response indicates success (merged, not error)
HAS_MERGED=$(printf '%s' "$RESPONSE" | grep -ciE 'merged|Merged|successfully' || true)
if [ "$HAS_MERGED" = "0" ]; then
  exit 0
fi

# Extract PR number from command
PR_NUM=$(printf '%s' "$CMD" | grep -oE 'merge[[:space:]]+([0-9]+)' | grep -oE '[0-9]+' | head -1 || true)

# Resolve the project dir for the board path hint (env / git root).
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || echo "<project>")}"
# Escape for JSON string embedding (a Windows path's backslashes would be invalid JSON escapes,
# silently dropping the whole additionalContext). Same idiom as the sibling hooks.
PROJECT_DIR_ESC=$(printf '%s' "$PROJECT_DIR" | sed 's/\\/\\\\/g; s/"/\\"/g')

# Per-session per-PR throttle. C-04: key on session_id PARSED FROM STDIN, not the
# undefined ${CLAUDE_SESSION_ID} env var (which collapses to "unknown" → a cross-session/
# cross-repo shared sentinel that suppresses the reminder machine-globally).
SESSION_ID=$(json_get "$PAYLOAD" session_id)
[ -z "$SESSION_ID" ] && SESSION_ID="unknown"
SENTINEL="${TMPDIR:-/tmp}/aal-post-merge-cleanup-${SESSION_ID}-pr${PR_NUM}.flag"
if [ -f "$SENTINEL" ]; then
  exit 0
fi
touch "$SENTINEL" 2>/dev/null || true
find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'aal-post-merge-cleanup-*.flag' -mtime +2 -delete 2>/dev/null || true

cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "POST-MERGE CHECKLIST for PR #${PR_NUM} (do ALL NOW — every one rots if deferred):\n1. UPDATE the task board ($PROJECT_DIR_ESC/.claude/BACKLOG.md) — the SINGLE source of truth: move the wave to the Done section + add a '— log:' line with the merge SHA. (The harness task store is NOT canonical; BACKLOG.md is.)\n2. Remove this wave's worktrees: git worktree remove --force <its worktree dir> (verify via 'git worktree list')\n3. Delete branches LOCAL + REMOTE (the merge's --delete-branch handles the remote; remove any local tracking branch). Squash-merged branches → match 'gh pr list --state merged --json headRefName', not is-ancestor.\n4. Doc-sync: did this change documented behavior? yes → update the docs; no → record 'doc-sync: SKIP — <reason>'."
  }
}
EOF
exit 0

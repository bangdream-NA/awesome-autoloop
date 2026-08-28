#!/usr/bin/env bash

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

# The merge test goes through lib/merge-intent.sh, the ONE owner of "is this an actual merge
# invocation". Grepping the whole command here instead fires on any command that merely QUOTES
# the phrase — `grep -rho 'gh pr merge 1472 --squash' notes.md` produced a full post-merge
# checklist for a PR nobody merged. Two files ask this question; a second private predicate is how
# they drift apart.
# shellcheck source=lib/merge-intent.sh
. "$(dirname "$0")/lib/merge-intent.sh" 2>/dev/null || true
if command -v is_merge_invocation >/dev/null 2>&1; then
  IS_MERGE=0; is_merge_invocation "$CMD" && IS_MERGE=1
else
  IS_MERGE=$(printf '%s' "$CMD" | grep -cE '\bgh[[:space:]]+pr[[:space:]]+merge\b' || true)
fi
if [ "$IS_MERGE" = "0" ]; then
  exit 0
fi

HAS_MERGED=$(printf '%s' "$RESPONSE" | grep -ciE 'merged|Merged|successfully' || true)
if [ "$HAS_MERGED" = "0" ]; then
  exit 0
fi

PR_NUM=$(printf '%s' "$CMD" | grep -oE 'merge[[:space:]]+([0-9]+)' | grep -oE '[0-9]+' | head -1 || true)
# A merge command with no resolvable PR number yields an empty PR_NUM, and the reminder then
# names no pull request at all. Silence is the correct output when the gate cannot say WHICH
# PR it is talking about.
[ -z "$PR_NUM" ] && exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || echo "<project>")}"
PROJECT_DIR_ESC=$(printf '%s' "$PROJECT_DIR" | sed 's/\\/\\\\/g; s/"/\\"/g')

SESSION_ID=$(json_get "$PAYLOAD" session_id)
[ -z "$SESSION_ID" ] && SESSION_ID="unknown"
# This hook is mounted on TWO events, so the event name it ECHOES has to be the one it RECEIVED.
# Hard-coding "PostToolUse" makes the harness reject the response outright ("Hook returned incorrect
# event name") on the other mount — and the failing path is the one that runs when a command
# FAILED, i.e. exactly when the reminder matters.
EVENT=$(printf '%s' "$PAYLOAD" | node -e "let s=''; process.stdin.on('data',c=>s+=c); process.stdin.on('end',()=>{try{const o=JSON.parse(s);process.stdout.write(o.hook_event_name||'')}catch{}});" 2>/dev/null || echo "")
[ -z "$EVENT" ] && EVENT="PostToolUse"
SENTINEL="${TMPDIR:-/tmp}/aal-post-merge-cleanup-${SESSION_ID}-pr${PR_NUM}.flag"
if [ -f "$SENTINEL" ]; then
  exit 0
fi
touch "$SENTINEL" 2>/dev/null || true
find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'aal-post-merge-cleanup-*.flag' -mtime +2 -delete 2>/dev/null || true

cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "$EVENT",
    "additionalContext": "POST-MERGE CHECKLIST for PR #${PR_NUM} (do ALL NOW — every one rots if deferred):\n1. UPDATE the task board ($PROJECT_DIR_ESC/.claude/BACKLOG.md) — the SINGLE source of truth: move the wave to the Done section + add a '— log:' line with the merge SHA. (The harness task store is NOT canonical; BACKLOG.md is.)\n2. Remove this wave's worktrees: git worktree remove --force <its worktree dir> (verify via 'git worktree list')\n3. Delete branches LOCAL + REMOTE (the merge's --delete-branch handles the remote; remove any local tracking branch). Squash-merged branches → match 'gh pr list --state merged --json headRefName', not is-ancestor.\n4. Doc-sync: did this change documented behavior? yes → update the docs; no → record 'doc-sync: SKIP — <reason>'."
  }
}
EOF
exit 0

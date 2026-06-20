#!/usr/bin/env bash
# remind-shutdown-done-agent.sh — PostToolUse hook (matcher: Bash).
#
# Fires at the deliverable-accepted moment: a successful `gh pr merge <N>` → shut down that
# PR's FRESH code-reviewer (+ any dev/planner/plan-reviewer whose wave just merged). No shell
# hook can SendMessage-shutdown for you; this is the nudge. (The harness task store is banned,
# so the dead TaskCompleted event can't carry this — it lives on the merge event instead.)
set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":pipeline-roles:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
source "$(dirname "$0")/lib/parse-json.sh"
aal_have_node || exit 0

PAYLOAD=$(cat)

TOOL=$(printf '%s' "$PAYLOAD" | node -e "let s='';process.stdin.on('data',c=>s+=c);process.stdin.on('end',()=>{try{process.stdout.write(JSON.parse(s).tool_name||'')}catch{}});" 2>/dev/null || echo "")
[ "$TOOL" = "Bash" ] || exit 0

CMD=$(printf '%s' "$PAYLOAD" | node -e "let s='';process.stdin.on('data',c=>s+=c);process.stdin.on('end',()=>{try{const o=JSON.parse(s);process.stdout.write((o.tool_input&&o.tool_input.command)||'')}catch{}});" 2>/dev/null || echo "")
RESPONSE=$(printf '%s' "$PAYLOAD" | node -e "let s='';process.stdin.on('data',c=>s+=c);process.stdin.on('end',()=>{try{const r=JSON.parse(s).tool_response;process.stdout.write(typeof r==='string'?r:JSON.stringify(r)||'')}catch{}});" 2>/dev/null || echo "")

# Only fire on a SUCCESSFUL `gh pr merge`
printf '%s' "$CMD" | grep -qE '\bgh[[:space:]]+pr[[:space:]]+merge\b' || exit 0
printf '%s' "$RESPONSE" | grep -qiE 'merged|successfully|squash' || exit 0

PR_NUM=$(printf '%s' "$CMD" | grep -oE 'merge[[:space:]]+#?[0-9]+' | grep -oE '[0-9]+' | head -1 || true)

# Per-session per-PR throttle (avoid double-fire on retries). C-04: key on session_id
# PARSED FROM STDIN, not the undefined ${CLAUDE_SESSION_ID} env var (collapses to "unknown"
# → a shared cross-session/cross-repo sentinel that suppresses the reminder machine-globally).
SESSION_ID=$(json_get "$PAYLOAD" session_id)
[ -z "$SESSION_ID" ] && SESSION_ID="unknown"
SENTINEL="${TMPDIR:-/tmp}/aal-shutdown-reviewer-${SESSION_ID}-pr${PR_NUM}.flag"
[ -f "$SENTINEL" ] && exit 0
touch "$SENTINEL" 2>/dev/null || true
find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'aal-shutdown-reviewer-*.flag' -mtime +2 -delete 2>/dev/null || true

cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"shutdown-on-accept: PR #${PR_NUM} merge succeeded → its deliverable is ACCEPTED. SHUT DOWN the FRESH code-reviewer for this PR NOW — SendMessage shutdown_request to codereview-${PR_NUM} (or whatever you named this PR's reviewer) PLUS any dev/planner/plan-reviewer whose wave just merged. config.json 'members' PRUNES on shutdown, freeing the roster slot. Do NOT reuse the agent for the next wave — respawn fresh."}}
EOF
exit 0

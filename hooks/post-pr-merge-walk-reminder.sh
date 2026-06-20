#!/usr/bin/env bash
# post-pr-merge-walk-reminder.sh — PostToolUse hook (matcher: Bash).
#
# Codifies the "every PR merge ends with a live-artifact verification walk" constraint: a wave
# is not ship-complete at merge — the final, user-facing artifact must be verified. After a
# successful `gh pr merge` Bash call, inject additionalContext nudging the lead to dispatch (or
# do) that walk, and write a pending-walk sentinel the Stop gate (check-unwalked-merges.sh)
# enforces at turn-end.
#
# Soft (no decision:block — the merge is done; this is a "don't forget the next step" prompt).
# A "walk" = a recorded post-merge verification of the live/final artifact in .claude/walks/.

set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":dod-walk:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0

source "$(dirname "$0")/lib/parse-json.sh"

# Discipline nudge, not a security gate → fail OPEN on node-absent (skip rather than break).
aal_have_node || exit 0

INPUT=$(cat)

TOOL=$(json_get "$INPUT" tool_name)
[ "$TOOL" = "Bash" ] || exit 0

CMD=$(json_get "$INPUT" command)

# Match gh pr merge invocations only
echo "$CMD" | grep -qE '\bgh[[:space:]]+pr[[:space:]]+merge\b' || exit 0

# Only fire on apparent success (tool_response mentions a merge outcome).
# Conservative: if we can't read response, skip rather than spam.
# tool_response is arbitrary tool output (NOT the hook-envelope shape json_get knows) → inline node.
RESPONSE=$(printf '%s' "$INPUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>{try{const j=JSON.parse(s);const r=j.tool_response||{};process.stdout.write([r.stdout,r.output,r.stderr].filter(Boolean).join("\n"))}catch{}})' 2>/dev/null || echo "")
echo "$RESPONSE" | grep -qiE 'merged|merging|squash|already merged|✓' || exit 0

# Extract PR number for the reminder
PR_NUM=$(echo "$CMD" | grep -oE 'gh pr merge[[:space:]]+[0-9]+' | grep -oE '[0-9]+' | head -1)
PR_LABEL="${PR_NUM:-?}"

# Per-session throttle (avoid double-fire if hook re-invoked on retries)
SESSION_ID=$(json_get "$INPUT" session_id)
STATE_DIR="$(dirname "$0")/.state"
mkdir -p "$STATE_DIR" 2>/dev/null || true
SENTINEL="$STATE_DIR/walk-reminded-${SESSION_ID}-pr${PR_LABEL}.flag"
[ -f "$SENTINEL" ] && exit 0
touch "$SENTINEL" 2>/dev/null || true
# Best-effort prune of stale sentinels (>2 days)
find "$STATE_DIR" -name 'walk-reminded-*.flag' -mtime +2 -delete 2>/dev/null || true

# HARD-GATE sentinel: write a pending-walk marker that the Stop hook
# (check-unwalked-merges.sh) enforces at turn-end. Cleared automatically when a
# walk artifact in .claude/walks/ mentions this PR# (or when marked N/A there).
if [ -n "$PR_NUM" ]; then
  # Resolve the project repo's .claude/walks dir (works from canonical or worktree)
  REPO_DIR=$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || echo "")
  if [ -n "$REPO_DIR" ]; then
    GIT_COMMON=$(git -C "$REPO_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || echo "")
    MAIN_REPO=$(dirname "$GIT_COMMON" 2>/dev/null || echo "$REPO_DIR")
    WALKS_DIR="$MAIN_REPO/.claude/walks"
    [ -d "$WALKS_DIR" ] && touch "$WALKS_DIR/.pending-pr${PR_NUM}" 2>/dev/null || true
  fi
fi

cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"PR #${PR_LABEL} merge succeeded. A wave is NOT ship-complete at merge — verify the live/final artifact per your project's nature before considering it done. For a web app, a real-browser walk (Playwright) or a curl of the deployed page; for a CLI, run the built binary; for a library, exercise the public API. Your project's CLAUDE.md/rules define what 'the walk' means. Pre-merge static + CI checks are necessary but not sufficient — the live walk catches deploy/cache/build-pipeline issues invisible to static checks. Record a .claude/walks/*.md artifact mentioning this PR# (or 'PR #N: non-UI, walk N/A — <reason>')."}}
EOF
exit 0

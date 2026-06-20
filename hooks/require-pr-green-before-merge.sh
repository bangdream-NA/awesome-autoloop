#!/usr/bin/env bash
# PreToolUse hook on Bash: BLOCK gh pr merge unless ship gates pass.
#
# Auto-merge is authorized only via a gate-driven contract:
#   - PR state OPEN, not draft
#   - All required CI checks SUCCESS (no FAILURE / IN_PROGRESS / QUEUED)
#   - Code review verdict APPROVED at the current PR HEAD SHA
#   - mergeStateStatus not DIRTY/BLOCKED/BEHIND
# Requires `gh`.

set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":merge-gates:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0

source "$(dirname "$0")/lib/parse-json.sh"
source "$(dirname "$0")/lib/verdict.sh"

if ! aal_have_node; then
  cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: awesome-autoloop requires node on PATH to evaluate this gate, and node was not found. Install node >=18, or disable the plugin / remove this gate group from AAL_GATES. (Fail-closed: a security gate that can't evaluate must not silently allow.)"}}
JSON
  exit 0
fi

INPUT=$(cat)
COMMAND=$(json_get "$INPUT" command)

# Only intercept `gh pr merge`
echo "$COMMAND" | grep -qE '\bgh[[:space:]]+pr[[:space:]]+merge\b' || exit 0

# Resolve project dir + cd into it so gh + git subprocesses inherit repo context
# (PreToolUse hook is spawned with the parent shell's cwd, NOT the cwd implied by
# `cd <project> && gh pr merge` — so we must resolve + cd ourselves).
HOOK_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
# If the command leads with `cd X && ...`, honor that target dir
LEADING_CD_DIR=$(aal_extract_cd_target "$COMMAND")
if [ -n "$LEADING_CD_DIR" ] && [ -d "$LEADING_CD_DIR" ]; then
  HOOK_PROJECT_DIR="$LEADING_CD_DIR"
fi
cd "$HOOK_PROJECT_DIR" 2>/dev/null || true

# Resolve PR number — explicit arg first, else current branch
PR_NUM=$(echo "$COMMAND" | grep -oE 'gh[[:space:]]+pr[[:space:]]+merge[[:space:]]+[0-9]+' | grep -oE '[0-9]+$' || echo "")
if [ -z "$PR_NUM" ]; then
  PR_NUM=$(gh pr view --json number --jq .number 2>/dev/null || echo "")
fi

deny() {
  cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED merge of PR #${PR_NUM:-?}: $1"}}
EOF
  exit 0
}

[ -z "$PR_NUM" ] && deny "cannot resolve PR number. Either run from a feature branch with an open PR, or pass the PR number explicitly: gh pr merge <N>"

# Check 1: PR open + not draft
STATE=$(gh pr view "$PR_NUM" --json state --jq .state 2>/dev/null || echo "")
[ -z "$STATE" ] && deny "gh pr view #$PR_NUM failed. Verify auth and PR exists."
[ "$STATE" != "OPEN" ] && deny "PR state=$STATE (not OPEN)"

IS_DRAFT=$(gh pr view "$PR_NUM" --json isDraft --jq .isDraft 2>/dev/null || echo "")
[ "$IS_DRAFT" = "true" ] && deny "PR is a draft — mark ready for review first"

# Check 2: mergeStateStatus
MERGE_STATE=$(gh pr view "$PR_NUM" --json mergeStateStatus --jq .mergeStateStatus 2>/dev/null || echo "UNKNOWN")
case "$MERGE_STATE" in
  DIRTY|BLOCKED|BEHIND) deny "mergeStateStatus=$MERGE_STATE (rebase or resolve conflicts)" ;;
esac

# Check 3: CI rollup — any FAILURE?
FAILING=$(gh pr view "$PR_NUM" --json statusCheckRollup --jq '[.statusCheckRollup[]? | select(.conclusion=="FAILURE" or .conclusion=="CANCELLED" or .conclusion=="TIMED_OUT" or .state=="FAILURE" or .state=="ERROR") | .name] | join(",")' 2>/dev/null || echo "")
[ -n "$FAILING" ] && deny "CI failing: $FAILING"

# Check 4: CI rollup — any IN_PROGRESS / QUEUED?
PENDING=$(gh pr view "$PR_NUM" --json statusCheckRollup --jq '[.statusCheckRollup[]? | select(.status=="IN_PROGRESS" or .status=="QUEUED" or .status=="PENDING" or .state=="PENDING") | .name] | join(",")' 2>/dev/null || echo "")
[ -n "$PENDING" ] && deny "CI still running: $PENDING"

# Check 5: review APPROVED bound to current HEAD SHA
HEAD_SHA=$(gh pr view "$PR_NUM" --json headRefOid --jq .headRefOid 2>/dev/null || echo "")
[ -z "$HEAD_SHA" ] && deny "cannot fetch headRefOid"
HEAD_SHORT="${HEAD_SHA:0:7}"

# Reuse HOOK_PROJECT_DIR (already resolved + cd'd to). If we're inside a worktree
# (.git/worktrees/* common-dir), walk up to the main repo for code-reviews.md.
PROJECT_DIR="$HOOK_PROJECT_DIR"
COMMON_DIR=$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")
case "$COMMON_DIR" in
  */.git/worktrees/*)
    # worktree case: --git-common-dir gives the main repo's .git path
    MAIN_GIT="${COMMON_DIR%/worktrees/*}"
    PROJECT_DIR="${MAIN_GIT%/.git}"
    ;;
esac

# --- Structured verdict fast-path: .claude/reviews/index.jsonl (exact pr + HEAD-SHA) ---
# ADDITIVE + SAFE: a matching record gives a precise verdict (no substring footgun —
# the markdown grep `NEEDS FIXES` below false-trips on any mention). If there is NO
# matching record, we fall THROUGH to the markdown grep, so older/unmigrated reviews
# still gate exactly as before — this can only ever be stricter or equal, never looser.
JSONL_FILE="$PROJECT_DIR/.claude/reviews/index.jsonl"
if [ -f "$JSONL_FILE" ] && command -v node >/dev/null 2>&1; then
  JV=$(cat "$JSONL_FILE" | node -e "
    let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{
      let v='';
      for(const line of d.split('\n')){ if(!line.trim()) continue;
        try{ const r=JSON.parse(line);
          if(String(r.pr)==='$PR_NUM' && typeof r.head_sha==='string' && r.head_sha.indexOf('$HEAD_SHORT')===0){ v=String(r.verdict||''); }
        }catch(_){}
      }
      console.log(v);
    });
  " 2>/dev/null)
  case "$(classify_jsonl_verdict "$JV")" in
    allow) exit 0 ;;  # structured APPROVED bound to current HEAD — gate passes
    deny)  deny "structured review verdict for #$PR_NUM @ $HEAD_SHORT is $JV (.claude/reviews/index.jsonl)" ;;
    *)     : ;;  # no matching record / APPROVED_WITH_* / unknown → fall through to markdown parser
  esac
fi

REVIEW_FILE="$PROJECT_DIR/.claude/code-reviews.md"
[ ! -f "$REVIEW_FILE" ] && deny "no .claude/code-reviews.md at $PROJECT_DIR — dispatch code-reviewer Mode B first"

# Find latest review block for this PR (allow R/R2 entries; take the most recent)
LAST_BLOCK_LINE=$(grep -nE "^## PR #${PR_NUM}\b" "$REVIEW_FILE" | tail -1 | cut -d: -f1 || echo "")
[ -z "$LAST_BLOCK_LINE" ] && deny "no review entry for this PR in code-reviews.md"

# Bound the block at the next `^## ` header (or EOF). Without bounding, the block
# spans into other reviews' "NEEDS FIXES" / older verdicts → false-positive deny.
NEXT_HEADER_LINE=$(awk -v start="$LAST_BLOCK_LINE" 'NR > start && /^## / { print NR; exit }' "$REVIEW_FILE")
if [ -z "$NEXT_HEADER_LINE" ]; then
  LATEST_BLOCK=$(sed -n "${LAST_BLOCK_LINE},\$p" "$REVIEW_FILE")
else
  END_LINE=$((NEXT_HEADER_LINE - 1))
  LATEST_BLOCK=$(sed -n "${LAST_BLOCK_LINE},${END_LINE}p" "$REVIEW_FILE")
fi

# Shared verdict parser (lib/verdict.sh): LAST explicit verdict candidate in the block wins,
# a rejection token beats a same-line/other-round APPROVED, header (...) history is stripped,
# only EXACT APPROVED allows; ambiguous/unrecognized fail CLOSED.
VERDICT_DECISION=$(printf '%s' "$LATEST_BLOCK" | decide_verdict)
case "$VERDICT_DECISION" in
  APPROVED)    : ;;  # fall through to the HEAD-SHA binding check below
  DENY:*)      deny "latest review verdict is a rejection (${VERDICT_DECISION#DENY:}) — dispatch dev R2 + reviewer R2" ;;
  AMBIGUOUS:*) deny "latest review verdict is ambiguous (${VERDICT_DECISION#AMBIGUOUS:}) — only an explicit 'VERDICT: APPROVED' allows merge; re-state the verdict" ;;
  *)           deny "no explicit verdict line in the latest review block for #$PR_NUM — reviewer must write 'VERDICT: APPROVED @<sha>'" ;;
esac

# HEAD-SHA marker — require (HEAD|@)<sha> in latest review block.
# Allow Markdown bold (** wrapping) + backtick code fences between marker and SHA.
if ! echo "$LATEST_BLOCK" | grep -qiE "(HEAD|@)[*\`[:space:]]*:?[*\`[:space:]]*${HEAD_SHORT}"; then
  deny "APPROVED but doesn't reference current PR HEAD ($HEAD_SHORT) — likely review is for older commit; dispatch reviewer R2"
fi

# All gates passed
exit 0

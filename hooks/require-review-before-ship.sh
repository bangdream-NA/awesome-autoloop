#!/usr/bin/env bash

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

if ! echo "$COMMAND" | grep -qE '\b(git[[:space:]]+push|gh[[:space:]]+pr[[:space:]]+merge)\b'; then
  exit 0
fi

#   1. CLAUDE_PROJECT_DIR env (set by Claude Code at session start)
if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
  PROJECT_DIR="$CLAUDE_PROJECT_DIR"
else
  COMMON_DIR=$(git rev-parse --git-common-dir 2>/dev/null || echo "")
  if [ -n "$COMMON_DIR" ]; then
    case "$COMMON_DIR" in
      /*|[A-Za-z]:*) ;;
      *) COMMON_DIR="$(pwd)/$COMMON_DIR" ;;
    esac
    case "$COMMON_DIR" in
      */.git) PROJECT_DIR="${COMMON_DIR%/.git}" ;;
      *) PROJECT_DIR=$(dirname "$COMMON_DIR") ;;
    esac
  else
    PROJECT_DIR=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  fi
fi
LEADING_CD_DIR=$(aal_extract_cd_target "$COMMAND")
if [ -n "$LEADING_CD_DIR" ] && [ -d "$LEADING_CD_DIR" ]; then PROJECT_DIR="$LEADING_CD_DIR"; fi
cd "$PROJECT_DIR" 2>/dev/null || true
REVIEW_FILE="$PROJECT_DIR/.claude/code-reviews.md"



CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "")
case "$CURRENT_BRANCH" in
  main|master|trunk) exit 0 ;;
esac

HEAD_SHORT=$(git rev-parse --short=7 HEAD 2>/dev/null || echo "")

if [ -z "$HEAD_SHORT" ]; then
  [ -f "$REVIEW_FILE" ] || exit 0
  if [ "$(tail -40 "$REVIEW_FILE" | decide_verdict)" != "APPROVED" ]; then
    cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: Latest code review is not APPROVED. Run /review and get APPROVED verdict before committing. (Degraded mode — no HEAD SHA bind because not in a git repo.)"}}
EOF
    exit 0
  fi
  exit 0
fi

PR_NUM=""
if command -v gh >/dev/null 2>&1; then
  PR_NUM=$(gh pr view --json number --jq .number 2>/dev/null || echo "")
fi

IS_MERGE=0; echo "$COMMAND" | grep -qE '\bgh[[:space:]]+pr[[:space:]]+merge\b' && IS_MERGE=1
HAS_PR=0; [ -n "$PR_NUM" ] && HAS_PR=1
LOCAL_EQ=1
if [ "$IS_MERGE" = 0 ] && [ "$HAS_PR" = 1 ]; then
  PR_HEAD=$(gh pr view --json headRefOid --jq .headRefOid 2>/dev/null || echo "")
  LOCAL_FULL=$(git rev-parse HEAD 2>/dev/null || echo "")
  if [ -n "$PR_HEAD" ] && [ -n "$LOCAL_FULL" ] && [ "$PR_HEAD" != "$LOCAL_FULL" ]; then LOCAL_EQ=0; fi
fi
[ "$(ship_decision "$IS_MERGE" "$HAS_PR" "$LOCAL_EQ")" = "allow" ] && exit 0

JSONL_FILE="$PROJECT_DIR/.claude/reviews/index.jsonl"
if [ -f "$JSONL_FILE" ]; then
  JV=$(cat "$JSONL_FILE" | node -e "
    let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{let v='';
      for(const line of d.split('\n')){ if(!line.trim()) continue;
        try{ const r=JSON.parse(line);
          if(String(r.pr)==='$PR_NUM' && typeof r.head_sha==='string' && r.head_sha.indexOf('$HEAD_SHORT')===0){ v=String(r.verdict||''); }
        }catch(_){}
      } console.log(v); });" 2>/dev/null)
  case "$(classify_jsonl_verdict "$JV")" in
    allow) exit 0 ;;
    deny)  cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: PR #${PR_NUM} structured review verdict is ${JV} (.claude/reviews/index.jsonl)."}}
EOF
           exit 0 ;;
    *)     : ;;
  esac
fi

PV=$(ls "$PROJECT_DIR/.claude/reviews/pr${PR_NUM}-r"*.md 2>/dev/null | sort -V | tail -1 || true)
if [ -n "$PV" ] && [ -f "$PV" ]; then
  LATEST_BLOCK=$(cat "$PV")
else
  [ -f "$REVIEW_FILE" ] || { cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: PR #$PR_NUM has no review entry — no .claude/reviews/pr${PR_NUM}-r*.md and no .claude/code-reviews.md. Dispatch code-reviewer Mode B before pushing."}}
EOF
    exit 0; }
  LAST_HEADER_LINE=$(grep -nE "^## PR #${PR_NUM}\b" "$REVIEW_FILE" | tail -1 | cut -d: -f1 || echo "")
  if [ -z "$LAST_HEADER_LINE" ]; then
    cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: PR #$PR_NUM has no review entry in .claude/reviews/pr${PR_NUM}-r*.md or .claude/code-reviews.md. Dispatch code-reviewer Mode B before pushing."}}
EOF
    exit 0
  fi
  LATEST_BLOCK=$(sed -n "${LAST_HEADER_LINE},\$p" "$REVIEW_FILE")
fi

RVERDICT=$(printf '%s' "$LATEST_BLOCK" | decide_verdict)
if [ "$RVERDICT" != "APPROVED" ]; then
  cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: PR #${PR_NUM} latest review verdict is not a clean APPROVED (${RVERDICT}). Address findings + dispatch reviewer R2 — only an explicit 'VERDICT: APPROVED' allows push."}}
EOF
  exit 0
fi

if ! echo "$LATEST_BLOCK" | grep -qiE "(HEAD|@)[*\`[:space:]]*:?[*\`[:space:]]*${HEAD_SHORT}"; then
  cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: Latest review is APPROVED but doesn't reference current HEAD ($HEAD_SHORT) via 'HEAD: <sha>' or '@ <sha>' marker. Likely the review is for a prior commit. Dispatch reviewer R2 on current HEAD, or have the reviewer add 'HEAD: $HEAD_SHORT' to the latest review block."}}
EOF
  exit 0
fi

exit 0

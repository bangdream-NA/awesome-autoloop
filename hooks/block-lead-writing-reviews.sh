#!/usr/bin/env bash
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":pipeline-roles:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
. "$(dirname "$0")/lib/log-denial.sh" 2>/dev/null || true
set -euo pipefail

INPUT=$(cat)

json_get() { printf '%s' "$1" | node -e "let s='';process.stdin.on('data',c=>s+=c);process.stdin.on('end',()=>{try{const o=JSON.parse(s);process.stdout.write($2)}catch{}});" 2>/dev/null || printf ''; }

TOOL=$(json_get "$INPUT" "o.tool_name||''")

AGENT_TYPE=$(json_get "$INPUT" "o.agent_type||''")
if [ -n "$AGENT_TYPE" ]; then
  exit 0
fi

deny() {
  aal_log_denial "block-lead-writing-reviews" "site-1" "deny" 2>/dev/null || true
  cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: the team lead cannot write or edit review verdict records (.claude/reviews/index.jsonl, or any per-review *.md) — a lead writing the verdict IS self-approval. FIX: if the reviewer left out its jsonl row or its .md, SendMessage and have IT add them. Target: $1"}}
EOF
  exit 0
}

case "$TOOL" in
  Write|Edit|MultiEdit)
    # shellcheck disable=SC1003  # the '\' is a literal backslash for tr, not a quote escape
    FP=$(json_get "$INPUT" "o.tool_input&&o.tool_input.file_path||''" | tr '\\' '/')
    if printf '%s' "$FP" | grep -qiE '/\.claude/reviews/'; then
      deny "$FP"
    fi
    ;;
  Bash)
    HIT=$(printf '%s' "$INPUT" | node "$(dirname "$0")/lib/reviews-write-detect.mjs" 2>/dev/null || echo "")
    [ "$HIT" = "HIT" ] && deny "(bash write into .claude/reviews/)"
    ;;
esac

exit 0

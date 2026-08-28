#!/usr/bin/env bash

set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":pipeline-roles:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
source "$(dirname "$0")/lib/parse-json.sh"
aal_have_node || exit 0

PAYLOAD=$(cat)

TOOL=$(printf '%s' "$PAYLOAD" | node -e "let s=''; process.stdin.on('data',c=>s+=c); process.stdin.on('end',()=>{try{const o=JSON.parse(s);process.stdout.write(o.tool_name||'')}catch{}});" 2>/dev/null || echo "")
if [ "$TOOL" != "SendMessage" ]; then
  exit 0
fi

MSG=$(printf '%s' "$PAYLOAD" | node -e "let s=''; process.stdin.on('data',c=>s+=c); process.stdin.on('end',()=>{try{const o=JSON.parse(s);const inp=o.tool_input||{};const to=inp.to||'';let m=inp.message;if(typeof m==='string'){try{m=JSON.parse(m)}catch{m=null}}const isShutdown=!!(m&&typeof m==='object'&&m.type==='shutdown_request');if(to.startsWith('dev-')&&isShutdown){process.stdout.write(to)}else{process.stdout.write('')}}catch{process.stdout.write('')}});" 2>/dev/null || echo "")

if [ -z "$MSG" ]; then
  exit 0
fi

cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "DEV SHUTDOWN ('${MSG}'). CONDITIONAL: IF this dev has an un-reviewed in-flight PR (its delivery is NOT yet code-reviewed+merged) → dispatch a FRESH code-reviewer (Mode B) in THIS SAME response; delivery + reviewer dispatch must be atomic. IF this is post-merge / idle roster cleanup (its PR already has an APPROVED verdict and is merged) → IGNORE this; do NOT dispatch a phantom reviewer for already-reviewed work. Check first-hand (gh pr view / .claude/reviews/) before dispatching."
  }
}
EOF
exit 0

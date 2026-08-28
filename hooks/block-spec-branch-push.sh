#!/usr/bin/env bash
. "$(dirname "$0")/lib/is-autoloop-lead.sh" 2>/dev/null || true
_AAL_MAIN=$(aal_resolve_repo "$INPUT" 2>/dev/null || echo "")
[ -z "$_AAL_MAIN" ] && _AAL_MAIN="<your main checkout>"
_AAL_WT=$(aal_worktree_parent "$_AAL_MAIN" 2>/dev/null || echo "")
[ -z "$_AAL_WT" ] && _AAL_WT="<your worktree parent dir>"
. "$(dirname "$0")/lib/log-denial.sh" 2>/dev/null || true

set -euo pipefail

PAYLOAD=$(cat)

TOOL=$(printf '%s' "$PAYLOAD" | node -e "let s=''; process.stdin.on('data',c=>s+=c); process.stdin.on('end',()=>{try{const o=JSON.parse(s);process.stdout.write(o.tool_name||'')}catch{}});" 2>/dev/null || echo "")
if [ "$TOOL" != "Bash" ]; then
  exit 0
fi

CMD=$(printf '%s' "$PAYLOAD" | node -e "let s=''; process.stdin.on('data',c=>s+=c); process.stdin.on('end',()=>{try{const o=JSON.parse(s);process.stdout.write((o.tool_input&&o.tool_input.command)||'')}catch{}});" 2>/dev/null || echo "")

IS_PUSH=$(printf '%s' "$CMD" | grep -cE '\bgit[[:space:]]+push\b' || true)
if [ "$IS_PUSH" = "0" ]; then
  exit 0
fi

IS_DELETE=$(printf '%s' "$CMD" | grep -cE '\bgit[[:space:]]+push[[:space:]]+origin[[:space:]]+--delete\b' || true)
if [ "$IS_DELETE" != "0" ]; then
  exit 0
fi

BRANCH=""

BRANCH=$(printf '%s' "$CMD" | grep -oE 'git[[:space:]]+push[[:space:]][^;|&]*' | head -1 | \
  sed -E 's/.*origin[[:space:]]+//' | \
  sed -E 's/^-[^ ]+[[:space:]]*//' | \
  sed -E 's/^([^:[:space:]]+):?.*/\1/' | \
  tr -d '[:space:]' || true)

if [ -z "$BRANCH" ] || [ "$BRANCH" = "origin" ]; then
  EFFECTIVE_CWD=$(printf '%s' "$CMD" | grep -oE 'cd[[:space:]]+[^[:space:]&;]+' | tail -1 | sed -E 's/^cd[[:space:]]+//' || true)
  if [ -n "$EFFECTIVE_CWD" ] && [ -d "$EFFECTIVE_CWD" ]; then
    BRANCH=$(git -C "$EFFECTIVE_CWD" branch --show-current 2>/dev/null || true)
  fi
  if [ -z "$BRANCH" ]; then
    BRANCH=$(git branch --show-current 2>/dev/null || true)
  fi
fi

case "$BRANCH" in
  main|master)
    exit 0
    ;;
  *-dev|*-dev-*)
    exit 0
    ;;
  fix/*|hotfix/*|chore/*)
    exit 0
    ;;
esac

SPEC_MATCH=$(printf '%s' "$BRANCH" | grep -cE '(-plan$|-plan-|-arch$|-arch-|-design$|-design-|-planreview$|-planreview-)' || true)
if [ "$SPEC_MATCH" != "0" ]; then
  aal_log_denial "block-spec-branch-push" "site-1" "deny" 2>/dev/null || true
  cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "BLOCKED: pushing spec branch '$BRANCH' to remote. Plan/arch/design/planreview branches stay LOCAL — only push the final dev branch after code-reviewer APPROVED + CI green.\n\nPipeline flow:\n  plan (local) -> plan-reviewer (local) -> arch (local) -> design (local) -> dev (local) -> code-reviewer APPROVED -> THEN push dev branch + open PR + merge.\nSpec branches are read from the local worktree ($_AAL_WT/*); they never go through GitHub."
  }
}
EOF
  exit 0
fi

exit 0

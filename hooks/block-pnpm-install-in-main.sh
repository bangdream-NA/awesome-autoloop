#!/usr/bin/env bash
set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":commit-hygiene:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
source "$(dirname "$0")/lib/parse-json.sh"
if ! aal_have_node; then
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED (pnpm-install-in-main): node is not available to evaluate this command. Install dependencies inside an isolated worktree, or append  # ALLOW_MAIN_INSTALL  to bypass."}}'
  exit 0
fi

INPUT=$(cat)
CMD=$(json_get "$INPUT" command)
CWD=$(json_get "$INPUT" cwd)

if ! echo "$CMD" | grep -Eq '(^|&&|;|\|)[[:space:]]*pnpm[[:space:]]+(install|i|add|up|update)([[:space:]]|$)'; then
  exit 0
fi

if echo "$CMD" | grep -q 'ALLOW_MAIN_INSTALL'; then
  exit 0
fi

MAIN_RE="${AAL_MAIN_REPO:-}"
[ -n "$MAIN_RE" ] || exit 0

CTX="$CMD $CWD"

WT_RE="${AAL_WORKTREE_ROOT:-}"
if [ -n "$WT_RE" ] && echo "$CTX" | grep -Eqi "$WT_RE"; then
  exit 0
fi

if echo "$CTX" | grep -Eqi "$MAIN_RE"; then
  cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: pnpm install in the shared main checkout. An aborted install here wipes node_modules/.pnpm + bins and breaks the shared pre-push hook for the whole session. Install ONLY inside an isolated worktree. Deliberate lead recovery: append the marker  # ALLOW_MAIN_INSTALL  to the command."}}
EOF
  exit 0
fi

exit 0

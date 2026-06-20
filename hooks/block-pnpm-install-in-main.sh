#!/usr/bin/env bash
# block-pnpm-install-in-main.sh — PreToolUse(Bash) guard. Refuse a dependency install in the
# SHARED MAIN checkout. An aborted install there wipes node_modules/.pnpm + bins and breaks the
# shared pre-push hook for the WHOLE session; installs belong in an isolated per-wave worktree.
# A deliberate lead recovery appends the marker  # ALLOW_MAIN_INSTALL  to the command.
#
# NO-OP UNLESS CONFIGURED: this gate only ever fires when you set AAL_MAIN_REPO (a token that
# matches your main checkout's path/cwd, e.g. the repo dir name) in your settings.json env. A
# single-tree / non-node project leaves it unset and gets a clean no-op + zero residue.
set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":commit-hygiene:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
source "$(dirname "$0")/lib/parse-json.sh"
# Fail CLOSED on node-absent: a deny gate must not silently allow an unguarded main-repo install.
if ! aal_have_node; then
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED (pnpm-install-in-main): node is not available to evaluate this command. Install dependencies inside an isolated worktree, or append  # ALLOW_MAIN_INSTALL  to bypass."}}'
  exit 0
fi

INPUT=$(cat)
CMD=$(json_get "$INPUT" command)
CWD=$(json_get "$INPUT" cwd)

# Only pnpm install-class commands at a command boundary (don't match the text inside a quoted git message etc.)
if ! echo "$CMD" | grep -Eq '(^|&&|;|\|)[[:space:]]*pnpm[[:space:]]+(install|i|add|up|update)([[:space:]]|$)'; then
  exit 0
fi

# Deliberate lead-recovery escape hatch.
if echo "$CMD" | grep -q 'ALLOW_MAIN_INSTALL'; then
  exit 0
fi

# Only a project that opted in (AAL_MAIN_REPO set) is guarded. Unset → clean no-op.
MAIN_RE="${AAL_MAIN_REPO:-}"
[ -n "$MAIN_RE" ] || exit 0

CTX="$CMD $CWD"

# Installs inside an isolated worktree are fine.
WT_RE="${AAL_WORKTREE_ROOT:-}"
if [ -n "$WT_RE" ] && echo "$CTX" | grep -Eqi "$WT_RE"; then
  exit 0
fi

# Targets the shared main checkout -> DENY.
if echo "$CTX" | grep -Eqi "$MAIN_RE"; then
  cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: pnpm install in the shared main checkout. An aborted install here wipes node_modules/.pnpm + bins and breaks the shared pre-push hook for the whole session. Install ONLY inside an isolated worktree. Deliberate lead recovery: append the marker  # ALLOW_MAIN_INSTALL  to the command."}}
EOF
  exit 0
fi

exit 0

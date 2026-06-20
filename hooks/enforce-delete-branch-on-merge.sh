#!/usr/bin/env bash
# PreToolUse/Bash: require `--delete-branch` on `gh pr merge`.
# Branches pile up because merges omit --delete-branch AND squash-merge hides them
# from `git branch --merged` so they never auto-clean. Forcing --delete-branch deletes
# the remote + local tracking branch at merge time, killing the remote pile at the source.
set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":merge-gates:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0

source "$(dirname "$0")/lib/parse-json.sh"

if ! aal_have_node; then
  cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: awesome-autoloop requires node on PATH to evaluate this gate, and node was not found. Install node >=18, or disable the plugin / remove this gate group from AAL_GATES. (Fail-closed: a security gate that can't evaluate must not silently allow.)"}}
JSON
  exit 0
fi

INPUT=$(cat)
COMMAND=$(json_get "$INPUT" command)

# Only gate `gh pr merge`.
echo "$COMMAND" | grep -qE 'gh[[:space:]]+pr[[:space:]]+merge' || exit 0

# Allow if --delete-branch present (any position).
if echo "$COMMAND" | grep -qE -- '--delete-branch'; then
  exit 0
fi

cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: `gh pr merge` must include --delete-branch. Branches pile up (squash-merge hides them from `git branch --merged`) — deleting at merge time is the fix. Re-run with --delete-branch. (Intentional keep? merge in the GitHub UI.)"}}
EOF
exit 0

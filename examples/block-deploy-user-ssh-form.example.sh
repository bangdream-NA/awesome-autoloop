#!/usr/bin/env bash
. "$(dirname "$0")/lib/log-denial.sh" 2>/dev/null || true

set -euo pipefail
source "$(dirname "$0")/lib/parse-json.sh"

INPUT=$(cat)
COMMAND=$(json_get "$INPUT" command)

HOST="<your-host>"
DEPLOY_SCRIPT="<your-deploy-script>"

echo "$COMMAND" | grep -qE "\bssh[[:space:]]+[^[:space:]]+@${HOST}\b" || exit 0
echo "$COMMAND" | grep -qF "$DEPLOY_SCRIPT" && exit 0

  aal_log_denial "block-deploy-user-ssh-form" "site-1" "deny" 2>/dev/null || true
cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: ssh must use the HOST ALIAS, not user@host. A user@host form does not match the allow rule and is classified as a raw prod mutation. FIX: drop the user - run  ssh <your-host>  instead of  ssh <user>@<your-host> . The deploy script's own --host <user>@<your-host> argument is not affected by this gate."}}
EOF
exit 0

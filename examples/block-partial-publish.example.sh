#!/usr/bin/env bash
. "$(dirname "$0")/lib/log-denial.sh" 2>/dev/null || true

set -euo pipefail

source "$(dirname "$0")/lib/parse-json.sh"

INPUT=$(cat)
COMMAND=$(json_get "$INPUT" command)

PUBLISH_ENDPOINT="<your-publish-endpoint>"

echo "$COMMAND" | grep -qE "${PUBLISH_ENDPOINT}.*[?&]entities=" || exit 0

if echo "$COMMAND" | grep -qE 'ALLOW_PARTIAL_PUBLISH_REPLACE=1'; then
  exit 0
fi

  aal_log_denial "block-partial-publish" "site-1" "deny" 2>/dev/null || true
cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: a publish carrying ?entities= is REPLACE semantics, not MERGE. The manifest is overwritten with only the entities you listed and every other one 404s until a full republish. FIX: drop the ?entities= parameter and run the full republish. If a partial replace really is what you mean, prefix the command with ALLOW_PARTIAL_PUBLISH_REPLACE=1."}}
EOF
exit 0

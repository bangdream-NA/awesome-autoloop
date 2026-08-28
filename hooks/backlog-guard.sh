#!/usr/bin/env bash
set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":pipeline-roles:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
source "$(dirname "$0")/lib/parse-json.sh"
if ! aal_have_node; then
  cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: awesome-autoloop needs node on PATH to evaluate backlog-guard, and node was not found. Install node >=18, or drop the pipeline-roles group from AAL_GATES. Fail-closed: a gate that cannot evaluate must not allow."}}
JSON
  exit 0
fi
exec node "$(dirname "$0")/backlog-guard.mjs" "$@"

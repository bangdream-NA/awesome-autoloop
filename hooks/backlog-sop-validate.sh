#!/usr/bin/env bash
set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":pipeline-roles:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
source "$(dirname "$0")/lib/parse-json.sh"
if ! aal_have_node; then
  cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: awesome-autoloop requires node on PATH to evaluate this dispatch SOP gate, and node was not found. Install node >=18, or disable the plugin / remove the pipeline-roles group from AAL_GATES. (Fail-closed: a gate that can't evaluate must not silently allow an un-vetted dispatch.)"}}
JSON
  exit 0
fi
exec node "$(dirname "$0")/backlog-sop-validate.mjs" "$@"

#!/usr/bin/env bash
set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":pipeline-roles:"*) ;; *) exit 0 ;; esac
case "${AAL_STALLCHECK:-on}" in off|0|false|no) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
source "$(dirname "$0")/lib/parse-json.sh"
if ! aal_have_node; then
  cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: awesome-autoloop requires node on PATH to evaluate the stall-check-cron dispatch gate, and node was not found. Install node >=18, set AAL_STALLCHECK=off (interactive use), or remove the pipeline-roles group from AAL_GATES. (Fail-closed: a gate that can't evaluate must not silently allow an unguarded autonomous run.)"}}
JSON
  exit 0
fi
exec node "$(dirname "$0")/require-stallcheck-cron-before-dispatch.mjs"

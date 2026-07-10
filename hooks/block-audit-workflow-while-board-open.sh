#!/usr/bin/env bash
# block-audit-workflow-while-board-open.sh — node-optional wrapper (Workflow gate, deny fail-CLOSED).
# Runs the node-free activation + group guard, then execs the node body. A board-integrity gate that
# can't evaluate must NOT silently allow a premature audit -> node-absent fail-CLOSES (like
# block-backlog-status-drift.sh). Does NOT consume stdin (the .mjs reads fd 0 itself).
set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":pipeline-roles:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
source "$(dirname "$0")/lib/parse-json.sh"
if ! aal_have_node; then
  # Board-integrity Workflow gate: node-absent must NOT silently allow a premature audit -> fail-CLOSED.
  cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: awesome-autoloop requires node on PATH to evaluate this audit-gate, and node was not found. Install node >=18, or disable the plugin / remove the pipeline-roles group from AAL_GATES. (Fail-closed: a gate that can't verify the board is clear must not silently allow a premature audit.)"}}
JSON
  exit 0
fi
exec node "$(dirname "$0")/block-audit-workflow-while-board-open.mjs"

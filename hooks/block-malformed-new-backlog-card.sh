#!/usr/bin/env bash
# block-malformed-new-backlog-card.sh — thin Bash wrapper: runs the node-free activation + group
# guard, then execs the node body (block-malformed-new-backlog-card.mjs). The guard MUST precede
# node so a non-autoloop / deselected-group call no-ops before the node body reads stdin (AC-9).
# Mirrors the guard idiom in block-bare-agent.sh; does NOT consume stdin (the .mjs reads fd 0 itself).
set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":pipeline-roles:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
source "$(dirname "$0")/lib/parse-json.sh"
if ! aal_have_node; then
  # Write-time deny gate: node-absent must NOT silently allow a malformed new card → fail-CLOSED.
  cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: awesome-autoloop requires node on PATH to evaluate this BACKLOG.md write gate, and node was not found. Install node >=18, or disable the plugin / remove the pipeline-roles group from AAL_GATES. (Fail-closed: a gate that can't evaluate must not silently allow a malformed card.)"}}
JSON
  exit 0
fi
exec node "$(dirname "$0")/block-malformed-new-backlog-card.mjs"

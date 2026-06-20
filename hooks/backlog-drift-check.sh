#!/usr/bin/env bash
# backlog-drift-check.sh — thin Bash wrapper: runs the node-free activation + group guard, then
# execs the node body (backlog-drift-check.mjs). The guard MUST precede node so a non-autoloop /
# deselected-group call no-ops before the node body reads its environment (AC-9). Mirrors the guard
# idiom in block-bare-agent.sh; does NOT consume stdin (the .mjs reads no stdin — it's a Stop hook).
# node-guard is fail-OPEN (exit 0): a Stop-time drift detector must never wedge turn-end on a
# node-less box — blocking every turn-end is worse than skipping a discipline nudge (mirrors the
# dod-walk Stop gate's fail-OPEN asymmetry).
set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":pipeline-roles:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
source "$(dirname "$0")/lib/parse-json.sh"
if ! aal_have_node; then
  # Stop drift detector: node-absent → fail-OPEN (a discipline nudge must not wedge turn-end).
  exit 0
fi
exec node "$(dirname "$0")/backlog-drift-check.mjs"

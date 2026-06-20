#!/usr/bin/env bash
# require-stallcheck-cron-before-dispatch.sh — thin Bash wrapper: runs the node-free activation +
# group guard (plus the AAL_STALLCHECK soft-switch), then execs the node body
# (require-stallcheck-cron-before-dispatch.mjs). The guard MUST precede node so a non-autoloop /
# deselected-group call no-ops before the node body reads stdin. Does NOT consume stdin (the .mjs
# reads fd 0 itself).
#
# DENY node-guard (fail-CLOSED): the stall-check cron is an autonomous-run safety (idle-wait coverage
# Stop hooks cannot see). node-absent must NOT silently allow an unguarded run → deny.
set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":pipeline-roles:"*) ;; *) exit 0 ;; esac
# Onboarding soft-switch: an INTERACTIVE (non-autonomous) user who babysits dispatches does not
# need the autonomous-run stall-check cron. Default ON (the autonomous default). Set
# AAL_STALLCHECK=off (or 0/false/no) in settings.json env to opt out WITHOUT killing the group.
case "${AAL_STALLCHECK:-on}" in off|0|false|no) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
source "$(dirname "$0")/lib/parse-json.sh"
if ! aal_have_node; then
  # Dispatch gate: node-absent must NOT silently allow an unguarded autonomous run → fail-CLOSED.
  cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: awesome-autoloop requires node on PATH to evaluate the stall-check-cron dispatch gate, and node was not found. Install node >=18, set AAL_STALLCHECK=off (interactive use), or remove the pipeline-roles group from AAL_GATES. (Fail-closed: a gate that can't evaluate must not silently allow an unguarded autonomous run.)"}}
JSON
  exit 0
fi
exec node "$(dirname "$0")/require-stallcheck-cron-before-dispatch.mjs"

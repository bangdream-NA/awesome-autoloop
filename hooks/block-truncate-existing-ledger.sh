#!/usr/bin/env bash
# block-truncate-existing-ledger.sh — thin Bash wrapper: runs the node-free activation + group guard,
# then execs the node body (block-truncate-existing-ledger.mjs). The guard MUST precede node so a
# non-autoloop / deselected-group call no-ops before the node body reads stdin. Does NOT consume stdin
# (the .mjs reads fd 0 itself).
#
# FAIL-OPEN node-guard: this is a footgun-preventer (it stops a `>` from clearing an existing ledger),
# NOT a security gate — see the .mjs header. A node-absent box must NOT wedge the lead, so node-absent
# → exit 0 (allow), unlike the fail-CLOSED dispatch/merge gates.
set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":ledger-hygiene:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
source "$(dirname "$0")/lib/parse-json.sh"
aal_have_node || exit 0   # fail-OPEN: a footgun-preventer must not block a write when node is absent
exec node "$(dirname "$0")/block-truncate-existing-ledger.mjs"

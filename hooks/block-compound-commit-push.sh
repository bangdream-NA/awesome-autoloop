#!/usr/bin/env bash
# block-compound-commit-push.sh — thin Bash wrapper: runs the node-free activation + group guard,
# then execs the node body (block-compound-commit-push.mjs). The guard MUST precede node so a
# non-autoloop / deselected-group call no-ops before the node body reads stdin. Mirrors the wrapper
# idiom in block-malformed-new-backlog-card.sh; does NOT consume stdin (the .mjs reads fd 0 itself).
#
# FAIL-OPEN node-guard: this is a footgun-preventer (it stops a compound commit+push from silently
# dropping the commit), NOT a security gate — see the .mjs header. A node-absent box must NOT deny a
# legitimate commit, so node-absent → exit 0 (allow), unlike the fail-CLOSED dispatch/merge gates.
set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":commit-hygiene:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
source "$(dirname "$0")/lib/parse-json.sh"
aal_have_node || exit 0   # fail-OPEN: a footgun-preventer must not block a commit when node is absent
exec node "$(dirname "$0")/block-compound-commit-push.mjs"

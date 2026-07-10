#!/usr/bin/env bash
# block-backlog-archive-residue.sh — node-optional wrapper (PostToolUse board-integrity block).
# node-absent -> no-op: the PreToolUse block-backlog-status-drift gate already fail-closes writes
# on a node-less box, so this PostToolUse backstop never runs there.
set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":pipeline-roles:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
source "$(dirname "$0")/lib/parse-json.sh"
aal_have_node || exit 0
exec node "$(dirname "$0")/block-backlog-archive-residue.mjs"

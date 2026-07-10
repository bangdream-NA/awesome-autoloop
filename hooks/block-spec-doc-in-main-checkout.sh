#!/usr/bin/env bash
# block-spec-doc-in-main-checkout.sh — node-optional wrapper (deny, fail-OPEN).
# Worktree-hygiene footgun-preventer: node-absent -> no-op (mirrors block-compound-commit-push.sh),
# NOT a blanket write-deny.
set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":pipeline-roles:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
source "$(dirname "$0")/lib/parse-json.sh"
aal_have_node || exit 0   # fail-OPEN: a narrow worktree-hygiene nudge must not blanket-block writes
exec node "$(dirname "$0")/block-spec-doc-in-main-checkout.mjs"

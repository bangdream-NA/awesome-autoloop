#!/usr/bin/env bash

set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":pipeline-roles:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0

cat <<'EOF'
MANDATORY RULES (from hooks — cannot be ignored):
1. MUST use the 6-agent pipeline for ALL builds: Planner -> Plan-reviewer -> UIUX-designer (UI waves only) -> Architect -> Developer -> Code-reviewer
2. NEVER write app source code directly — dispatch a developer agent
3. NEVER use the bare Agent tool — pass a team_name string (any value) in the Agent call (no separate TeamCreate step; it was removed in Claude Code v2.1.178)
4. MUST push to GitHub after every commit
5. MUST save code reviews as a per-verdict file .claude/reviews/pr<N>-r<round>.md + one line in .claude/reviews/index.jsonl (gates read the jsonl first; code-reviews.md is frozen legacy)
6. NEVER push the .claude/ directory to GitHub
7. NEVER add Co-Authored-By lines to commits
EOF

exit 0

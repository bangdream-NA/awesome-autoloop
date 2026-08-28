#!/usr/bin/env bash
set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":pipeline-roles:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
source "$(dirname "$0")/lib/parse-json.sh"

if ! aal_have_node; then
  cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: awesome-autoloop requires node on PATH to evaluate this plan-review role gate, and node was not found. Install node >=18, or disable the plugin / remove the pipeline-roles group from AAL_GATES. (Fail-closed: a gate that can't evaluate must not silently allow a mis-routed dispatch.)"}}
JSON
  exit 0
fi

INPUT=$(cat)

TOOL=$(json_get "$INPUT" tool_name)
[ "$TOOL" = "Agent" ] || exit 0

SUBAGENT=$(json_get "$INPUT" subagent_type)
[ "$SUBAGENT" = "code-reviewer" ] || exit 0

PROMPT=$(json_get "$INPUT" prompt)

# NOT `b\\b`: with a FULL-WIDTH punctuation mark straight after "Mode B", whether `\\b` matches
# depends on how the running locale classifies those bytes, and in the failing case it did not —
# a legitimate Mode-B review was denied and routed to the plan-reviewer. An explicit
# "followed by a non-alphanumeric, or end of string" says the same thing locale-independently.
if echo "$PROMPT" | grep -qiE 'mode[[:space:]*_-]*b([^[:alnum:]]|$)'; then
  exit 0
fi

if echo "$PROMPT" | grep -qiE 'mode[[:space:]*_-]*a\b|plan[-_ ]doc|review the plan|R-[A-Za-z0-9._-]+-plan\.md|post-planner|pre-architect|plan review'; then
  cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: use subagent_type \"plan-reviewer\" (NOT code-reviewer) for Mode-A plan-doc review. There is a dedicated plan-reviewer agent for post-Planner/pre-Architect review; code-reviewer is Mode B (post-Dev PR review) only. Re-spawn with subagent_type: \"plan-reviewer\". See the spawn-team skill."}}
EOF
  exit 0
fi

exit 0

#!/usr/bin/env bash
# PreToolUse/Agent: BLOCK spawning `code-reviewer` for a Mode-A PLAN-DOC review.
# The pipeline has a DEDICATED `plan-reviewer` agent for Mode A (post-Planner,
# pre-Architect); `code-reviewer` is Mode B only (post-Dev PR review). Spawning
# code-reviewer for plan review was a recurring lead mistake — the spawn-team
# skill + memory document the split but documentation alone didn't stop it
# (rules-without-observability-are-blind). This gate is the enforcement layer.
#
# Fires ONLY when subagent_type == code-reviewer AND the prompt carries a strong
# Mode-A plan-review signal AND no explicit Mode-B marker → deny + tell the lead
# to use subagent_type: plan-reviewer. Precise signals keep legit Mode-B spawns
# (which may mention "the plan/spec") from false-positiving.
set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":pipeline-roles:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
source "$(dirname "$0")/lib/parse-json.sh"

if ! aal_have_node; then
  # PreToolUse(Agent) dispatch gate: node-absent must NOT silently allow a mis-routed plan review → fail-CLOSED.
  cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: awesome-autoloop requires node on PATH to evaluate this plan-review role gate, and node was not found. Install node >=18, or disable the plugin / remove the pipeline-roles group from AAL_GATES. (Fail-closed: a gate that can't evaluate must not silently allow a mis-routed dispatch.)"}}
JSON
  exit 0
fi

INPUT=$(cat)

# Only gate the Agent tool.
TOOL=$(json_get "$INPUT" tool_name)
[ "$TOOL" = "Agent" ] || exit 0

SUBAGENT=$(json_get "$INPUT" subagent_type)
[ "$SUBAGENT" = "code-reviewer" ] || exit 0

PROMPT=$(json_get "$INPUT" prompt)

# Explicit Mode-B marker → this is a legit code review, allow.
if echo "$PROMPT" | grep -qiE 'mode[[:space:]*_-]*b\b'; then
  exit 0
fi

# Strong Mode-A / plan-doc signals.
if echo "$PROMPT" | grep -qiE 'mode[[:space:]*_-]*a\b|plan[-_ ]doc|review the plan|R-[A-Za-z0-9._-]+-plan\.md|post-planner|pre-architect|plan review'; then
  cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: use subagent_type \"plan-reviewer\" (NOT code-reviewer) for Mode-A plan-doc review. There is a dedicated plan-reviewer agent for post-Planner/pre-Architect review; code-reviewer is Mode B (post-Dev PR review) only. Re-spawn with subagent_type: \"plan-reviewer\". See the spawn-team skill."}}
EOF
  exit 0
fi

exit 0

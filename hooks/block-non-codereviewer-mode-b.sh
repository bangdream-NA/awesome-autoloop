#!/usr/bin/env bash
set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":pipeline-roles:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
source "$(dirname "$0")/lib/parse-json.sh"
aal_have_node || exit 0
INPUT=$(cat)
TOOL=$(json_get "$INPUT" tool_name)
[ "$TOOL" = "Agent" ] || exit 0
SUBAGENT=$(json_get "$INPUT" subagent_type)
case "$SUBAGENT" in
  code-reviewer|plan-reviewer|planner|uiux-designer) exit 0 ;;
esac
PROMPT=$(json_get "$INPUT" prompt)
if echo "$PROMPT" | grep -qiE 'code[ -]?review of (the |this )?pr|\breview (the |this |open )*pr\b|mode-b-code-review'; then
  cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: a Mode-B / PR code-review must be subagent_type=code-reviewer (you passed '${SUBAGENT}'). The 6-agent pipeline's Reviewer role = the plugin's own agents/code-reviewer.md (Mode B); ~/.claude/agents/ is the OVERRIDE site, not the definition site. An architect/planner/developer reviewing a PR is OFF-ROLE AND carries that agent's prior-wave context, defeating review independence + the worktree/context-isolation intent. Re-spawn a FRESH code-reviewer: Agent({subagent_type:'code-reviewer', name:'codereview-<PR#>'}) with the review brief in the spawn prompt. One reviewer = one PR = fresh context; NEVER reuse an agent that touched the wave or a sibling."}}
EOF
  exit 0
fi
exit 0

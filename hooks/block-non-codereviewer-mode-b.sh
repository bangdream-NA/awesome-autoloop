#!/usr/bin/env bash
# PreToolUse(Agent) — the INVERSE of block-codereviewer-for-plan-review.
# A Mode-B / PR code-review MUST be dispatched to subagent_type=code-reviewer.
# Architects / planners / developers doing PR code-review = OFF-ROLE (violates the
# 5-agent pipeline's distinct Reviewer role) AND carries their prior-wave conversation
# context (defeats review independence + the worktree-isolation intent).
# Default ALLOW (exit 0); DENY only when a Mode-B dispatch targets a non-code-reviewer.
set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":pipeline-roles:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
source "$(dirname "$0")/lib/parse-json.sh"
# Node absent → can't parse the payload to evaluate the NARROW off-role match.
# A static deny here would OVER-BLOCK every Agent spawn (this gate is default-ALLOW),
# so noop instead; the SessionStart preflight loudly warns node is missing.
aal_have_node || exit 0
INPUT=$(cat)
TOOL=$(json_get "$INPUT" tool_name)
[ "$TOOL" = "Agent" ] || exit 0
SUBAGENT=$(json_get "$INPUT" subagent_type)
# Categorically NOT a PR code-review role → allow immediately. Each has its own distinct
# lane/gate (code-reviewer = Mode B; plan-reviewer = Mode A plan docs; planner/uiux-designer
# never review PRs). Only genuinely-ambiguous types (architect/developer/...) fall through.
case "$SUBAGENT" in
  code-reviewer|plan-reviewer|planner|uiux-designer) exit 0 ;;
esac
PROMPT=$(json_get "$INPUT" prompt)
# Is this a Mode-B / PR code-review dispatch? Match only a genuine review IMPERATIVE
# ("code review of (the) PR", "review the/this/open PR", or explicit mode-b-code-review marker)
# — NOT an incidental context mention ("PR #130", "pin SHA", contrastive "Mode B",
# "code-reviews.md"), which would falsely deny plan-reviewer/architect briefs. The merge-time
# gate require-codereviewer-verdict-before-merge.sh is the hard backstop, so a narrow trigger
# here is safe.
if echo "$PROMPT" | grep -qiE 'code[ -]?review of (the |this )?pr|\breview (the |this |open )*pr\b|mode-b-code-review'; then
  cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: a Mode-B / PR code-review must be subagent_type=code-reviewer (you passed '${SUBAGENT}'). The 5-agent pipeline's Reviewer role = ~/.claude/agents/code-reviewer.md (Mode B). An architect/planner/developer reviewing a PR is OFF-ROLE AND carries that agent's prior-wave context, defeating review independence + the worktree/context-isolation intent. Re-spawn a FRESH code-reviewer: Agent({subagent_type:'code-reviewer', name:'codereview-<PR#>'}) with the review brief in the spawn prompt. One reviewer = one PR = fresh context; NEVER reuse an agent that touched the wave or a sibling."}}
EOF
  exit 0
fi
exit 0

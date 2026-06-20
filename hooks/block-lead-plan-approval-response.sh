#!/usr/bin/env bash
# block-lead-plan-approval-response.sh
# PreToolUse hook (matcher: SendMessage)
# Blocks team-lead from sending a `type: plan_approval_response` message directly.
# Plan approval is plan-reviewer Mode A's job — team-lead must dispatch the
# reviewer first, then forward the reviewer's verdict.
#
# stdin = harness-provided JSON: {tool_name, tool_input, ...}
# The tool_input.message field is what we inspect; if it carries the
# plan_approval_response type token (any whitespace), we block.
set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":pipeline-roles:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
source "$(dirname "$0")/lib/parse-json.sh"

if ! aal_have_node; then
  # PreToolUse(SendMessage) role gate: node-absent must NOT silently allow a lead self-approval → fail-CLOSED.
  cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: awesome-autoloop requires node on PATH to evaluate this plan-approval role gate, and node was not found. Install node >=18, or disable the plugin / remove the pipeline-roles group from AAL_GATES. (Fail-closed: a gate that can't evaluate must not silently allow a self-approval.)"}}
JSON
  exit 0
fi

PAYLOAD=$(cat)

# Quick check: tool_name must be SendMessage. If not, no-op.
TOOL=$(json_get "$PAYLOAD" tool_name)
if [ "$TOOL" != "SendMessage" ]; then
  exit 0
fi

# Extract the message body. It can be a string OR an object (the harness accepts
# both shapes per the SendMessage tool schema). json_get can't stringify an object
# (it returns "[object Object]"), so stringify here: a string passes through, an
# object is JSON.stringified — then grep the literal type token either way.
MSG=$(printf '%s' "$PAYLOAD" | node -e "
let s='';
process.stdin.on('data',c=>s+=c);
process.stdin.on('end',()=>{
  try {
    const o = JSON.parse(s);
    const m = o.tool_input && o.tool_input.message;
    if (m == null) { process.stdout.write(''); return; }
    if (typeof m === 'string') { process.stdout.write(m); return; }
    process.stdout.write(JSON.stringify(m));
  } catch {}
});
" 2>/dev/null || echo "")

# Token match — be permissive on whitespace around the colon and around quotes.
if printf '%s' "$MSG" | grep -Eq '"type"[[:space:]]*:[[:space:]]*"plan_approval_response"'; then
  cat <<'JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "BLOCK — team-lead must NOT respond to a plan-approval request directly. Plan approval is plan-reviewer Mode A's job.\n\nCorrect flow:\n  1. On receiving a plan-approval request: dispatch plan-reviewer Mode A (Agent + subagent_type=plan-reviewer), pin the plan SHA + file path, wait for the reviewer's JSONL verdict.\n  2. Forward that verdict to the planner — using the reviewer's APPROVED/NEEDS-REVISION + quoted feedback, NOT your own judgment.\n  3. Minor team-lead-spotted issues (typos, AC fact errors) → pass to the reviewer as additional context, let the reviewer fold in.\n\nThe ONLY exception is responding approve:false AFTER the reviewer's verdict explicitly came back NEEDS-REVISION — and even then, the feedback must quote the reviewer's verdict, not invent new feedback."
  }
}
JSON
  exit 0
fi

exit 0

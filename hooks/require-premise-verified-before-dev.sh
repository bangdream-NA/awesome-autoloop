#!/usr/bin/env bash

set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":pipeline-roles:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
source "$(dirname "$0")/lib/parse-json.sh"

INPUT=$(cat)

echo "$INPUT" | grep -q '"subagent_type"[[:space:]]*:[[:space:]]*"developer"' || exit 0

echo "$INPUT" | grep -q 'PREMISE-VERIFIED' && exit 0

if ! aal_have_node; then
  cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED (verification death-constraint): awesome-autoloop requires node on PATH to evaluate this premise-verification gate, and node was not found. Install node >=18, or for a genuinely trivial no-premise change append  # PREMISE-VERIFIED: <the live evidence you gathered>  to the dispatch prompt to override."}}
JSON
  exit 0
fi

RES=$(printf '%s' "$INPUT" | node "$(dirname "$0")/lib/premise-target.mjs" 2>/dev/null)
[ "$RES" = "OK" ] && exit 0

case "$RES" in
  NOVERDICT*)
    WAVE=$(printf '%s' "$RES" | sed 's/^NOVERDICT[[:space:]]*//' | tr -cd 'A-Za-z0-9._-')
    REASON="BLOCKED (verification death-constraint): dispatching a developer for wave '${WAVE}' that has NO logged plan-review verdict in .claude/plan-reviews.md. A fix's PREMISE must be independently LIVE-verified FIRST (plan-reviewer Mode A — curl the shard / walk the painted page / read the official source), BEFORE any code. Dispatch the plan-reviewer for this wave first. For a genuinely trivial no-premise change, append  # PREMISE-VERIFIED: <the live evidence you gathered>  to the dispatch prompt to override."
    ;;
  *)
    REASON="BLOCKED (verification death-constraint): could not identify the TARGET wave of this developer dispatch from its explicit fields. Name the wave canonically in the prompt as  …for wave **<WAVE>**…  (or set the agent name to  dev-<wave> ) so its plan-review verdict can be checked, OR for a genuinely trivial no-premise change append  # PREMISE-VERIFIED: <the live evidence you gathered>  to override."
    ;;
esac

cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"${REASON}"}}
EOF
exit 0

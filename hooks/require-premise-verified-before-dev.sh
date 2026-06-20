#!/usr/bin/env bash
# PreToolUse(Agent) — VERIFICATION DEATH-CONSTRAINT.
# A hook cannot read whether you "really looked", BUT it CAN make the pipeline's independent
# live premise-verification MANDATORY before any fix CODE is written. No DEVELOPER (code-writer)
# dispatch for a wave unless that wave has a logged plan-review verdict in .claude/plan-reviews.md
# — the plan-reviewer (Mode A) re-verifies the premise against the LIVE artifact (curl the shard /
# walk the painted page / check the official source). This is the chokepoint that stops a
# developer being dispatched against an unverified (possibly phantom) bug premise.
#
# Thin Bash wrapper (.sh-wraps-.mjs): the node-free activation + group guard run first, then the
# wave-resolution logic runs in lib/premise-target.mjs. The guard MUST precede node so a
# non-autoloop / deselected-group call no-ops before the node body reads stdin.

set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":pipeline-roles:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
source "$(dirname "$0")/lib/parse-json.sh"

INPUT=$(cat)

# Only gate the code-writer (developer). Planner/plan-reviewer/architect/designer/reviewer pass.
echo "$INPUT" | grep -q '"subagent_type"[[:space:]]*:[[:space:]]*"developer"' || exit 0

# Escape hatch for a trivial no-premise wave (lead asserts live evidence inline).
echo "$INPUT" | grep -q 'PREMISE-VERIFIED' && exit 0

if ! aal_have_node; then
  # Death-constraint: a false ALLOW is worse than a false BLOCK (a false block is recoverable via the
  # PREMISE-VERIFIED escape). Node-absent → DENY (fail-CLOSED).
  cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED (verification death-constraint): awesome-autoloop requires node on PATH to evaluate this premise-verification gate, and node was not found. Install node >=18, or for a genuinely trivial no-premise change append  # PREMISE-VERIFIED: <the live evidence you gathered>  to the dispatch prompt to override."}}
JSON
  exit 0
fi

# Resolve the TARGET wave from EXPLICIT dispatch fields + verify it has a logged plan-review
# verdict. Logic in lib/premise-target.mjs (anchor-first, word-bounded fallback, fail-closed).
# Output: OK | NOVERDICT<TAB><wave> | NOWAVE. node error / any other output → DENY (fail-closed;
# for a death-constraint a false BLOCK is recoverable via PREMISE-VERIFIED, a false ALLOW is not).
# Emit stays pure-bash so the deny survives even if node vanished after resolution.
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

# REASON contains no  "  or  \  and WAVE is sanitized to [A-Za-z0-9._-] → valid
# JSON without escaping. Pure-bash emit (no node) keeps the deny fail-closed.
cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"${REASON}"}}
EOF
exit 0

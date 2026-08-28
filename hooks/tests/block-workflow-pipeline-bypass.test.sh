#!/usr/bin/env bash
set -u
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/block-workflow-pipeline-bypass.mjs
# The gate scopes itself by PROJECT NAME. Pin it here, so these arms do not depend on the
# directory the suite happens to run from.
export AAL_PROJECT_NAME="my-project"
PASS=0; FAIL=0; FAILURES=()

payload() {
  node -e 'process.stdout.write(JSON.stringify({tool_name:"Workflow", tool_input:{script:process.argv[1]}}))' "$1"
}
is_deny() { payload "$2" | node "$HOOK" 2>&1 | grep -q '"permissionDecision":"deny"'; }
deny()  { if is_deny "$1" "$2"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); FAILURES+=("EXPECTED-DENY: $1"); fi; }
allow() { if is_deny "$1" "$2"; then FAIL=$((FAIL + 1)); FAILURES+=("EXPECTED-ALLOW-BUT-DENIED: $1"); else PASS=$((PASS + 1)); fi; }

deny "in-scope code-reviewer agentType is a pipeline bypass" $'export const meta = { name: "review-parsergap", description: "PR review", phases: [] }\nawait agent("review Z:/my-project PR", { agentType: "code-reviewer" })'

deny "in-scope developer agentType remains blocked even under audit meta" $'export const meta = { name: "full-site-audit", description: "audit my-project", phases: [] }\nawait agent("change Z:/my-project", { agentType: "developer" })'

deny "in-scope non-audit default workflow agent is blocked" $'export const meta = { name: "repair-parser", description: "repair live parsing", phases: [] }\nawait agent("inspect Z:/my-project")'

allow "declared audit default agent defers to the separate audit gate" $'export const meta = { name: "full-site-audit", description: "audit my-project", phases: [] }\nawait agent("scan Z:/my-project")'

allow "foreign project default workflow is out of scope" $'export const meta = { name: "repair-other", description: "repair another app", phases: [] }\nawait agent("inspect Z:/other-project")'

allow "quoted pipeline-looking data is not an agent dispatch" $'export const meta = { name: "self-improve", description: "mine data", phases: [] }\nconst evidence = "agent(\\"review\\", { agentType: \\"code-reviewer\\" }) Z:/my-project"\nconsole.log(evidence)'

name="$(basename "$0")"
if [ "$FAIL" -eq 0 ]; then
  echo "  $name: PASS ($PASS/$PASS)"
  exit 0
fi

echo "  $name: FAIL ($PASS pass, $FAIL fail)"
for failure in "${FAILURES[@]}"; do echo "    - $failure"; done
exit 1

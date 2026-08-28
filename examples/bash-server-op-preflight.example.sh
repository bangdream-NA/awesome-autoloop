#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib/parse-json.sh"
source "$(dirname "$0")/lib/log-denial.sh"

INPUT=$(cat)
COMMAND=$(json_get "$INPUT" command || echo "")
[ -z "$COMMAND" ] && exit 0

if ! printf '%s' "$COMMAND" | grep -qE '\bssh\b|\bscp\b|<your-publish-command>|<your-deploy-script>|<your-pipeline-driver>|<your-ingest-cli>|wrangler[[:space:]]+deploy|<your-publish-endpoint>'; then
  exit 0
fi

HOOK_DIR="$(dirname "$0")"

source "$HOOK_DIR/lib/is-autoloop-lead.sh"
if ! aal_is_autoloop_lead "$INPUT"; then
  aal_log_denial "bash-server-op-preflight" "agent-server-op" "deny" 2>/dev/null || true
  cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: server operations are the LEAD's alone. ssh / scp / deploy / republish / v1-ingest / wrangler deploy are denied for subagents, regardless of what the allowlist says (settings.json permissions have no role axis, so the allow rule you matched is the lead's). If your brief asked you to measure something on the box, that brief is wrong: say so in your handoff, name the exact command you would have run and what you needed from it, and let the lead run it and hand you the reading. Do NOT rewrite the command to dodge this — no wrapper, no alias, no scp, no wrangler. Everything else in your brief you can still do: repo reads, source inspection, tests in your own worktree."}}
EOF
  exit 0
fi

source "$HOOK_DIR/lib/git-config-sanity.sh"
. "$HOOK_DIR/lib/is-autoloop-lead.sh" 2>/dev/null || true
_AAL_ROOTS=$(aal_known_projects 2>/dev/null || echo "")
for _root in $_AAL_ROOTS "${CLAUDE_PROJECT_DIR:-}"; do
  [ -n "$_root" ] || continue
  if _diag=$(git_config_poison "$_root"); then :; else
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' \
      "$(printf '%s' "$_diag" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.stringify(s)))')"
    exit 0
  fi
done

HOOKS=(
  "block-deploy-user-ssh-form.sh"
  "block-deploy-from-worktree.sh"
  "block-partial-publish.sh"
  "require-runbook-before-server-op.mjs"
)
for h in "${HOOKS[@]}"; do
  [ -f "$HOOK_DIR/$h" ] || continue
  if [[ "$h" == *.mjs ]]; then
    OUT=$(printf '%s' "$INPUT" | node "$HOOK_DIR/$h" 2>/dev/null || true)
  else
    OUT=$(printf '%s' "$INPUT" | bash "$HOOK_DIR/$h" 2>/dev/null || true)
  fi
  if [ -n "$OUT" ] && printf '%s' "$OUT" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
    SNIP=$(printf '%s' "$OUT" | grep -oE '"permissionDecisionReason"[^"]*"[^"]{0,140}' | head -1 | sed 's/^"permissionDecisionReason"[^"]*"//' || true)
    aal_log_denial "bash-server-op-preflight" "${h%.*}" "$SNIP"
    printf '%s' "$OUT"
    exit 0
  fi
  if [ -n "$OUT" ]; then
    printf '%s' "$OUT"
  fi
done

exit 0

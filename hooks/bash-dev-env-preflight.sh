#!/usr/bin/env bash
set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":commit-hygiene:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
source "$(dirname "$0")/lib/parse-json.sh"
source "$(dirname "$0")/lib/log-denial.sh"

INPUT=$(cat)
COMMAND=$(json_get "$INPUT" command || echo "")
[ -z "$COMMAND" ] && exit 0

if ! printf '%s' "$COMMAND" | grep -qE 'git[[:space:]]+worktree|pnpm[[:space:]]+(install|i\b|add)|\bpytest\b'; then
  exit 0
fi

HOOK_DIR="$(dirname "$0")"
HOOKS=(
  "block-multi-worktree-per-wave.sh"
  "block-pnpm-install-in-main.sh"
  "block-stale-worktree-pytest.sh"
)
for h in "${HOOKS[@]}"; do
  [ -f "$HOOK_DIR/$h" ] || continue
  OUT=$(printf '%s' "$INPUT" | bash "$HOOK_DIR/$h" 2>/dev/null || true)
  if [ -n "$OUT" ] && printf '%s' "$OUT" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
    SNIP=$(printf '%s' "$OUT" | grep -oE '"permissionDecisionReason"[^"]*"[^"]{0,140}' | head -1 | sed 's/^"permissionDecisionReason"[^"]*"//' || true)
    aal_log_denial "bash-dev-env-preflight" "${h%.*}" "$SNIP"
    printf '%s' "$OUT"
    exit 0
  fi
  if [ -n "$OUT" ]; then
    printf '%s' "$OUT"
  fi
done

exit 0

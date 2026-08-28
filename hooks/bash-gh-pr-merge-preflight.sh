#!/usr/bin/env bash
set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":merge-gates:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
source "$(dirname "$0")/lib/parse-json.sh"
source "$(dirname "$0")/lib/log-denial.sh"
source "$(dirname "$0")/lib/merge-intent.sh"

INPUT=$(cat)
COMMAND=$(json_get "$INPUT" command || echo "")
[ -z "$COMMAND" ] && exit 0

if ! is_merge_invocation "$COMMAND"; then
  exit 0
fi

source "$(dirname "$0")/lib/git-config-sanity.sh"
HOOK_DIR="$(dirname "$0")"
# (the registry only ever grows; backlog-guard stamps it on every real board write) plus the harness CLAUDE_PROJECT_DIR.
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
  "block-merge-on-board-drift.sh"
  "block-pr-merge-stale-base.sh"
  "require-pr-green-before-merge.sh"
  "require-codereviewer-verdict-before-merge.sh"
  "require-oplog-row-for-this-merge.sh"
  "require-backlog-reconciled-before-merge.sh"
  "enforce-delete-branch-on-merge.sh"
  "remind-walk-before-next-merge.sh"
)
for h in "${HOOKS[@]}"; do
  [ -f "$HOOK_DIR/$h" ] || continue
  OUT=$(printf '%s' "$INPUT" | bash "$HOOK_DIR/$h" 2>/dev/null || true)
  if [ -n "$OUT" ] && printf '%s' "$OUT" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
    SNIP=$(printf '%s' "$OUT" | grep -oE '"permissionDecisionReason"[^"]*"[^"]{0,140}' | head -1 | sed 's/^"permissionDecisionReason"[^"]*"//' || true)
    aal_log_denial "bash-gh-pr-merge-preflight" "${h%.*}" "$SNIP"
    printf '%s' "$OUT"
    exit 0
  fi
  if [ -n "$OUT" ]; then
    printf '%s' "$OUT"
  fi
done

exit 0

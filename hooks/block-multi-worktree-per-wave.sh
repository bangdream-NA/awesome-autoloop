#!/usr/bin/env bash

set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":pipeline-roles:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
source "$(dirname "$0")/lib/parse-json.sh"

if ! aal_have_node; then
  cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: awesome-autoloop requires node on PATH to evaluate this worktree-discipline gate, and node was not found. Install node >=18, or disable the plugin / remove the pipeline-roles group from AAL_GATES. (Fail-closed: a gate that can't evaluate must not silently allow.)"}}
JSON
  exit 0
fi

PAYLOAD=$(cat)

TOOL=$(json_get "$PAYLOAD" tool_name)
if [ "$TOOL" != "Bash" ]; then
  exit 0
fi

CMD=$(json_get "$PAYLOAD" command)

IS_WT_ADD=$(printf '%s' "$CMD" | grep -cE '\bgit[[:space:]]+worktree[[:space:]]+add\b' || true)
if [ "$IS_WT_ADD" = "0" ]; then
  exit 0
fi

IS_DETACH=$(printf '%s' "$CMD" | grep -cE '\-\-detach' || true)
if [ "$IS_DETACH" != "0" ]; then
  exit 0
fi

WT_ROOT="${AAL_WORKTREE_ROOT:-}"
[ -n "$WT_ROOT" ] || exit 0
STAGES="${AAL_WAVE_STAGES:-plan|arch|design|dev|review|planreview|planreview-r[0-9]+}"

TARGET_PATH=$(printf '%s' "$CMD" | grep -oE "${WT_ROOT}/[a-zA-Z0-9_./-]+" | head -1 || true)
if [ -z "$TARGET_PATH" ]; then
  exit 0
fi

WAVE=$(printf '%s' "$TARGET_PATH" | sed -E "s|^${WT_ROOT}/||" | sed -E "s/-(${STAGES})\$//")

# shellcheck disable=SC2012  # ls is fine here: worktree dir names are git-controlled slugs
EXISTING=$(ls -d "${WT_ROOT}/${WAVE}"* 2>/dev/null | head -5 || true)
if [ -z "$EXISTING" ]; then
  exit 0
fi

if [ -d "$TARGET_PATH" ]; then
  exit 0
fi

cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "BLOCKED: wave '$WAVE' already has worktree(s):\n$(echo "$EXISTING" | tr '\n' ',')\n\nRule: ONE worktree per wave. All stages (plan/arch/dev/review) share it. Use the existing worktree instead of creating a new one.\n\nException: --detach worktrees for read-only reviewers are allowed."
  }
}
EOF
exit 0

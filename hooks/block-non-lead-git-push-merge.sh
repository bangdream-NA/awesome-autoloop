#!/usr/bin/env bash

set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":pipeline-roles:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
source "$(dirname "$0")/lib/parse-json.sh"

if ! aal_have_node; then
  cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: awesome-autoloop requires node on PATH to evaluate this push/merge gate, and node was not found. Install node >=18, or disable the plugin / remove the pipeline-roles group from AAL_GATES. (Fail-closed: a gate that can't evaluate must not silently allow a push.)"}}
JSON
  exit 0
fi

PAYLOAD=$(cat)

TOOL=$(json_get "$PAYLOAD" tool_name)
if [ "$TOOL" != "Bash" ]; then
  exit 0
fi

CMD=$(json_get "$PAYLOAD" command)

IS_PUSH=$(printf '%s' "$CMD" | grep -cE '\bgit[[:space:]]+push\b' || true)
IS_GH_MUTATING=$(printf '%s' "$CMD" | grep -cE '\bgh[[:space:]]+pr[[:space:]]+(create|merge|edit|review|comment|reopen|close)\b|\bgh[[:space:]]+issue[[:space:]]+(create|edit|close|comment|reopen)\b' || true)

if [ "$IS_PUSH" = "0" ] && [ "$IS_GH_MUTATING" = "0" ]; then
  exit 0
fi

EFFECTIVE_CWD=$(aal_extract_cd_target "$CMD")
if [ -z "$EFFECTIVE_CWD" ]; then
  EFFECTIVE_CWD="$PWD"
fi

WT_RE="${AAL_WORKTREE_ROOT:-}"
case "$EFFECTIVE_CWD" in
  */.worktrees/*|*-wt/*)
    ;;
  *)
    if [ -n "$WT_RE" ] && case "$EFFECTIVE_CWD" in *"$WT_RE"/*) true ;; *) false ;; esac; then
      :
    else
      exit 0
    fi
    ;;
esac

OPERATION="git push"
[ "$IS_GH_MUTATING" != "0" ] && OPERATION="gh pr/issue mutating operation"

cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "BLOCKED: $OPERATION attempted from worktree dir '$EFFECTIVE_CWD'. Only team-lead pushes branches / creates PRs / merges. Agents commit LOCALLY only.\n\nCorrect flow (you = pipeline agent):\n  1. Commit your work locally with conventional message (no Co-Authored-By, no .claude/ staged)\n  2. SendMessage team-lead with: branch name, local commit SHA(s), file list, deviation flags, F-gate results, MANDATORY-handoff per agent .md\n  3. STOP. Team-lead inspects + rebases onto current origin/main + pushes + creates PR + dispatches reviewer / merges.\n\nIF you are team-lead and need to push from a worktree: 'cd <main-checkout-dir>' first (e.g. 'cd <your main repo> && git push ...'). This is rare; usually rebase + push happens from the main dir."
  }
}
EOF
exit 0

#!/usr/bin/env bash
# PreToolUse/Bash: BLOCK git commit containing Co-Authored-By
# Uses json_get (node) not inline grep: a naive `"[^"]*"` extraction truncates at
# the first quote of `git commit -m "..."` / heredoc commits and SILENTLY MISSES
# the Co-Authored-By line (the gate became theater). json_get returns the full
# unescaped command so the grep below actually sees the trailer.
set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":commit-hygiene:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0

source "$(dirname "$0")/lib/parse-json.sh"

if ! aal_have_node; then
  cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: awesome-autoloop requires node on PATH to evaluate this gate, and node was not found. Install node >=18, or disable the plugin / remove this gate group from AAL_GATES. (Fail-closed: a security gate that can't evaluate must not silently allow.)"}}
JSON
  exit 0
fi

INPUT=$(cat)
COMMAND=$(json_get "$INPUT" command)

# Only check git commit commands
echo "$COMMAND" | grep -qE 'git commit' || exit 0

# Block if commit message contains Co-Authored-By
if echo "$COMMAND" | grep -qi 'Co-Authored-By'; then
  cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: Co-Authored-By line detected in commit message. Remove it — this is a hard rule."}}
EOF
  exit 0
fi

exit 0

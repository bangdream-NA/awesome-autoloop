#!/usr/bin/env bash
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

echo "$COMMAND" | grep -qE 'git commit' || exit 0

mflags=$(printf '%s' "$COMMAND" | grep -oE '(-m|--message=?|-[a-z]*m)[[:space:]]*("([^"]*)"|'"'"'([^'"'"']*)'"'"')' || true)
MSG=$(printf '%s\n' "$mflags" | sed -nE '1{s/^(-m|--message=?|-[a-z]*m)[[:space:]]*"([^"]*)".*/\2/; s/^(-m|--message=?|-[a-z]*m)[[:space:]]*'"'"'([^'"'"']*)'"'"'.*/\2/; p;}')

if [ -z "$MSG" ]; then
  MSG=$(echo "$COMMAND" | sed -n 's/.*-m.*<<.*EOF[[:space:]]*//p' | head -1 || echo "")
fi

[ -z "$MSG" ] && exit 0

case "$MSG" in
  '$('*|'cat <<'*|'`'*) exit 0 ;;
esac

if ! echo "$MSG" | grep -qE '^(feat|fix|refactor|docs|test|chore|perf|ci|build|style)(\([^)]+\))?!?:[[:space:]]'; then
  cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: Commit message must follow conventional format: <type>(optional-scope)!?: <description>. Allowed types: feat|fix|refactor|docs|test|chore|perf|ci|build|style. Examples: 'feat: ...', 'fix(api): ...', 'refactor(web)!: breaking change'."}}
EOF
  exit 0
fi

exit 0

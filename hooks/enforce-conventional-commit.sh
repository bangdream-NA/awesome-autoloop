#!/usr/bin/env bash
# PreToolUse/Bash: BLOCK git commit if message doesn't follow conventional format
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

# Only check git commit (not amend)
echo "$COMMAND" | grep -qE 'git commit' || exit 0

# Extract the commit message. Match -m, -am/-vam (glued flags), --message=, --message <msg>.
MSG=$(echo "$COMMAND" | sed -nE "s/.*(-m|--message=?|-[a-z]*m)[[:space:]]*[\"']([^\"']*)[\"'].*/\2/p" | head -1 || echo "")

# If using heredoc/cat style, extract first line
if [ -z "$MSG" ]; then
  MSG=$(echo "$COMMAND" | sed -n 's/.*-m.*<<.*EOF[[:space:]]*//p' | head -1 || echo "")
fi

# Skip if we can't parse the message (let git handle it)
[ -z "$MSG" ] && exit 0

# Skip if message starts with $(...) command substitution OR `cat <<EOF...` —
# our regex can't introspect bash command output. Let git's commit-msg hook (if
# any) catch malformed messages at the natural runtime layer.
case "$MSG" in
  '$('*|'cat <<'*|'`'*) exit 0 ;;
esac

# Check conventional commit format: type(optional-scope)!: description
# Accepts: feat:, feat(web):, fix(api)!:, etc.
if ! echo "$MSG" | grep -qE '^(feat|fix|refactor|docs|test|chore|perf|ci|build|style)(\([^)]+\))?!?:[[:space:]]'; then
  cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: Commit message must follow conventional format: <type>(optional-scope)!?: <description>. Allowed types: feat|fix|refactor|docs|test|chore|perf|ci|build|style. Examples: 'feat: ...', 'fix(api): ...', 'refactor(web)!: breaking change'."}}
EOF
  exit 0
fi

exit 0

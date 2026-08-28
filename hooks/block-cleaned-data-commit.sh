#!/usr/bin/env bash
set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":commit-hygiene:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
source "$(dirname "$0")/lib/parse-json.sh"
if ! aal_have_node; then
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED (cleaned-data-commit): node is not available to parse this command; cannot verify the staged set is free of private data. Run the commit where node is available."}}'
  exit 0
fi

INPUT=$(cat)
COMMAND=$(json_get "$INPUT" command)

IS_COMMIT=0
IS_PUSH=0
echo "$COMMAND" | grep -qE 'git[[:space:]]+commit' && IS_COMMIT=1
echo "$COMMAND" | grep -qE 'git[[:space:]]+push' && IS_PUSH=1
[ "$IS_COMMIT" -eq 0 ] && [ "$IS_PUSH" -eq 0 ] && exit 0

BAD_PATTERN='(^|/)(canonical[^/]*\.json$|cleaned/|published/|snapshots/|.*\.dump$|.*\.sql\.gz$|.*\.parquet$|.*\.ndjson$)'
[ -n "${AAL_DATA_GLOBS:-}" ] && BAD_PATTERN="${BAD_PATTERN}|${AAL_DATA_GLOBS}"

CHANGED=""
SCOPE=""
if [ "$IS_COMMIT" -eq 1 ]; then
  CHANGED=$(git diff --cached --name-only 2>/dev/null || echo "")
  SCOPE="commit (staged)"
else
  BASE_REF="origin/main"
  git rev-parse --verify "$BASE_REF" >/dev/null 2>&1 || BASE_REF="main"
  CHANGED=$(git diff "$BASE_REF...HEAD" --name-only 2>/dev/null || echo "")
  SCOPE="push ($BASE_REF...HEAD)"
fi

[ -z "$CHANGED" ] && exit 0

BLOCKED=$(echo "$CHANGED" | grep -E "$BAD_PATTERN" || true)

if [ -n "$BLOCKED" ]; then
  PREVIEW=$(echo "$BLOCKED" | head -5 | tr '\n' ',' | sed 's/,$//')
  COUNT=$(echo "$BLOCKED" | wc -l)
  cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED $SCOPE: includes cleaned/canonical data ($COUNT file(s)): $PREVIEW. Cleaned records, snapshots, DB dumps, and exported shards are NOT open data. For commit: unstage with 'git restore --staged <path>'. For push: rewrite history to drop the file ('git rebase -i' + drop commits, OR 'git filter-repo'). If truly open data with license, bypass requires user '!' exec."}}
EOF
  exit 0
fi

exit 0

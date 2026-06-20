#!/usr/bin/env bash
# block-cleaned-data-commit.sh — PreToolUse(Bash). BLOCK a git commit/push whose changed files
# include cleaned/canonical data: DB dumps, published snapshots, exported shards, parquet/ndjson.
# These are private data-pipeline assets, NOT open data — they must never land in a public repo.
#
# The default pattern set is stack-agnostic. Add project-specific data paths via AAL_DATA_GLOBS
# (an ERE alternative appended to the blacklist, e.g. 'public-data/|data/v1/').
set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":commit-hygiene:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
source "$(dirname "$0")/lib/parse-json.sh"
# Fail CLOSED on node-absent: a data file slipping into a public commit is the worse outcome.
if ! aal_have_node; then
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED (cleaned-data-commit): node is not available to parse this command; cannot verify the staged set is free of private data. Run the commit where node is available."}}'
  exit 0
fi

INPUT=$(cat)
COMMAND=$(json_get "$INPUT" command)

# Intercept git commit AND git push.
# - commit: check `git diff --cached` (staged for THIS commit)
# - push:   check `origin/main...HEAD` (everything we're about to send)
# Push-side check matters because cleaned data could already be in committed
# history; push leaks it to GitHub even if current staging is clean.
IS_COMMIT=0
IS_PUSH=0
echo "$COMMAND" | grep -qE 'git[[:space:]]+commit' && IS_COMMIT=1
echo "$COMMAND" | grep -qE 'git[[:space:]]+push' && IS_PUSH=1
[ "$IS_COMMIT" -eq 0 ] && [ "$IS_PUSH" -eq 0 ] && exit 0

# Blacklist patterns. Stack-agnostic; extend with AAL_DATA_GLOBS for project-specific data paths.
BAD_PATTERN='(^|/)(canonical[^/]*\.json$|cleaned/|published/|snapshots/|.*\.dump$|.*\.sql\.gz$|.*\.parquet$|.*\.ndjson$)'
[ -n "${AAL_DATA_GLOBS:-}" ] && BAD_PATTERN="${BAD_PATTERN}|${AAL_DATA_GLOBS}"

CHANGED=""
SCOPE=""
if [ "$IS_COMMIT" -eq 1 ]; then
  CHANGED=$(git diff --cached --name-only 2>/dev/null || echo "")
  SCOPE="commit (staged)"
else
  # Push: resolve base ref (origin/main preferred, fallback main)
  BASE_REF="origin/main"
  git rev-parse --verify "$BASE_REF" >/dev/null 2>&1 || BASE_REF="main"
  CHANGED=$(git diff "$BASE_REF...HEAD" --name-only 2>/dev/null || echo "")
  SCOPE="push ($BASE_REF...HEAD)"
fi

[ -z "$CHANGED" ] && exit 0  # nothing to scan

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

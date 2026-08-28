#!/usr/bin/env bash
set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":merge-gates:"*) ;; *) exit 0 ;; esac
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

echo "$COMMAND" | grep -qE 'git push' || exit 0

LEADING_CD_DIR=$(aal_extract_cd_target "$COMMAND")
if [ -n "$LEADING_CD_DIR" ] && [ -d "$LEADING_CD_DIR" ]; then
  cd "$LEADING_CD_DIR" 2>/dev/null || true
elif [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
  cd "$CLAUDE_PROJECT_DIR" 2>/dev/null || true
fi

BRANCH=$(git branch --show-current 2>/dev/null || echo "")

echo "$BRANCH" | grep -qiE '^(main|master|chore|docs)' && exit 0

[ -z "$BRANCH" ] && exit 0

BASE_REF="origin/main"
git rev-parse --verify "$BASE_REF" >/dev/null 2>&1 || BASE_REF="main"

CHANGED=$(git diff "$BASE_REF...HEAD" --name-only 2>/dev/null || echo "")


KT_SRC=$(echo "$CHANGED" | grep -cE '\.kt$' || true)
KT_TEST=$(echo "$CHANGED" | grep -cE 'Test\.kt$|/test/' || true)
KT_SRC=${KT_SRC:-0}; KT_TEST=${KT_TEST:-0}

TS_ALL=$(echo "$CHANGED" | grep -cE '\.(ts|tsx)$' || true)
TS_TEST=$(echo "$CHANGED" | grep -cE '(__tests__/|\.test\.(ts|tsx)$|\.spec\.(ts|tsx)$)' || true)
TS_ALL=${TS_ALL:-0}; TS_TEST=${TS_TEST:-0}
TS_SRC=$((TS_ALL - TS_TEST))

SQL_SRC=$(echo "$CHANGED" | grep -cE '\.sql$' || true)
SQL_MIG=$(echo "$CHANGED" | grep -cE '(migrations?/|drizzle/).*\.sql$' || true)
SQL_SRC=${SQL_SRC:-0}; SQL_MIG=${SQL_MIG:-0}
SQL_NONMIG=$((SQL_SRC - SQL_MIG))

BLOCK=0
REASON=""

if [ "$KT_SRC" -gt 0 ] && [ "$KT_TEST" -eq 0 ]; then
  BLOCK=1
  REASON="Kotlin source changed ($KT_SRC files) but no .kt tests added/updated"
fi
if [ "$TS_SRC" -gt 0 ] && [ "$TS_TEST" -eq 0 ]; then
  BLOCK=1
  REASON="TypeScript source changed ($TS_SRC files) but no tests added (looked for __tests__/, *.test.ts(x), *.spec.ts(x))"
fi
if [ "$SQL_NONMIG" -gt 0 ] && [ "$SQL_MIG" -eq 0 ]; then
  BLOCK=1
  REASON="SQL schema changed ($SQL_NONMIG non-migration files) but no migration file added — bare schema edits skip existing DBs"
fi

if [ "$BLOCK" -eq 1 ]; then
  cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: $REASON. Edge testing is mandatory — add or update tests before pushing."}}
EOF
  exit 0
fi


if command -v gh >/dev/null 2>&1; then
  PR_NUM=$(gh pr view --json number --jq .number 2>/dev/null || echo "")
  PR_HEAD=$(gh pr view --json headRefOid --jq .headRefOid 2>/dev/null || echo "")
  LOCAL_HEAD=$(git rev-parse HEAD 2>/dev/null || echo "")

  if [ -n "$PR_NUM" ] && [ -n "$PR_HEAD" ] && [ "$LOCAL_HEAD" = "$PR_HEAD" ]; then
    FAILING=$(gh pr view --json statusCheckRollup --jq '[.statusCheckRollup[]? | select(.conclusion=="FAILURE" or .conclusion=="CANCELLED" or .conclusion=="TIMED_OUT" or .state=="FAILURE" or .state=="ERROR") | .name] | join(",")' 2>/dev/null || echo "")
    PENDING=$(gh pr view --json statusCheckRollup --jq '[.statusCheckRollup[]? | select(.status=="IN_PROGRESS" or .status=="QUEUED" or .status=="PENDING" or .state=="PENDING") | .name] | join(",")' 2>/dev/null || echo "")

    if [ -n "$FAILING" ]; then
      cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: PR #$PR_NUM has failing CI checks at current HEAD: $FAILING. Fix CI before pushing/merging."}}
EOF
      exit 0
    fi
    if [ -n "$PENDING" ]; then
      cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: PR #$PR_NUM has CI checks still running at current HEAD: $PENDING. Wait for green before pushing/merging."}}
EOF
      exit 0
    fi
  fi
fi

exit 0

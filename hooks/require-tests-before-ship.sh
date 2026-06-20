#!/usr/bin/env bash
# PreToolUse/Bash: BLOCK git push if a feature branch has no test changes.
# Only applies to feature branches (not main, not chore/docs branches).
# STACK ASSUMPTION (documented): the test-presence detection knows Kotlin (*Test.kt),
# TypeScript (__tests__/, *.test/spec.ts(x)), and SQL migrations. A stack it doesn't
# recognize produces no match → no block (degrades cleanly). Adapt the patterns below
# for your stack.
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

# Only check git push
echo "$COMMAND" | grep -qE 'git push' || exit 0

# Honor a leading `cd <dir> &&` so `cd <worktree> && git push` evaluates the
# WORKTREE branch, not the spawn-cwd's main (C-15). Mirrors require-review-before-ship.sh:53.
LEADING_CD_DIR=$(aal_extract_cd_target "$COMMAND")
if [ -n "$LEADING_CD_DIR" ] && [ -d "$LEADING_CD_DIR" ]; then
  cd "$LEADING_CD_DIR" 2>/dev/null || true
elif [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
  cd "$CLAUDE_PROJECT_DIR" 2>/dev/null || true
fi

# Get current branch
BRANCH=$(git branch --show-current 2>/dev/null || echo "")

# Skip for main (PR merge target) + chore/docs (no source changes expected).
# Do NOT skip for fix/hotfix — bugfix waves ARE the most likely place for test-less
# changes, and skipping them means multi-bug-fix PRs without a single edge test.
echo "$BRANCH" | grep -qiE '^(main|master|chore|docs)' && exit 0

# Skip if branch is empty (detached HEAD, etc)
[ -z "$BRANCH" ] && exit 0

# Prefer origin/main (avoids stale local main); fall back to local main.
BASE_REF="origin/main"
git rev-parse --verify "$BASE_REF" >/dev/null 2>&1 || BASE_REF="main"

# Collect changed files vs base
CHANGED=$(git diff "$BASE_REF...HEAD" --name-only 2>/dev/null || echo "")

# Stack-aware test-changes detection:
#   - Kotlin:      src = *.kt   test = *Test.kt or /test/
#   - TypeScript:  src = *.ts/*.tsx (excluding tests)
#                  test = __tests__/, *.test.ts(x), *.spec.ts(x)
#   - SQL migrations: src = *.sql; presence of new migrations counts as its own test
# grep -c outputs 0 and exits 1 on no match; capture both via || true.
#
# WEAK GATE NOTE: this checks "test files exist in the diff", NOT "tests actually
# passed". Future upgrade: record HEAD SHA + gate result in a sidecar log and
# only allow push if the latest pass matches the current SHA.

KT_SRC=$(echo "$CHANGED" | grep -cE '\.kt$' || true)
KT_TEST=$(echo "$CHANGED" | grep -cE 'Test\.kt$|/test/' || true)
KT_SRC=${KT_SRC:-0}; KT_TEST=${KT_TEST:-0}

TS_ALL=$(echo "$CHANGED" | grep -cE '\.(ts|tsx)$' || true)
TS_TEST=$(echo "$CHANGED" | grep -cE '(__tests__/|\.test\.(ts|tsx)$|\.spec\.(ts|tsx)$)' || true)
TS_ALL=${TS_ALL:-0}; TS_TEST=${TS_TEST:-0}
TS_SRC=$((TS_ALL - TS_TEST))

# SQL: any *.sql change must include a migration file (migrations/*.sql or
# drizzle/*.sql or similar). Bare schema.sql edits without a paired migration
# are silently skipped at deploy by most migration runners.
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

# HEAD SHA / CI binding: if a PR exists for current branch, require gh pr checks
# to show all required checks SUCCESS (no FAILURE / IN_PROGRESS / QUEUED).
# This is stronger than "file presence" — it proves the tests actually ran AND passed
# at the current HEAD via CI on origin.
#
# Degraded fallback: if gh not installed / no PR / not in repo → skip CI gate
# (file-presence above is the only gate in that case).

if command -v gh >/dev/null 2>&1; then
  # Use gh --jq for all field extraction; avoids python entirely.
  PR_NUM=$(gh pr view --json number --jq .number 2>/dev/null || echo "")
  PR_HEAD=$(gh pr view --json headRefOid --jq .headRefOid 2>/dev/null || echo "")
  LOCAL_HEAD=$(git rev-parse HEAD 2>/dev/null || echo "")

  # Only enforce if local HEAD matches PR head (otherwise we're about to push a new commit;
  # CI hasn't run yet — let it through, push will trigger a new CI run).
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

#!/usr/bin/env bash
set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":commit-hygiene:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
source "$(dirname "$0")/lib/parse-json.sh"
source "$(dirname "$0")/lib/log-denial.sh"

INPUT=$(cat)
COMMAND=$(json_get "$INPUT" command || echo "")
[ -z "$COMMAND" ] && exit 0

. "$(dirname "$0")/lib/merge-intent.sh"
IS_COMMIT=0; IS_PUSH=0
echo "$COMMAND" | grep -qE "git${GIT_GLOBAL_OPTS}[[:space:]]+commit" && IS_COMMIT=1
echo "$COMMAND" | grep -qE "git${GIT_GLOBAL_OPTS}[[:space:]]+push" && IS_PUSH=1
[ "$IS_COMMIT" -eq 0 ] && [ "$IS_PUSH" -eq 0 ] && exit 0

emit_deny() {
  aal_log_denial "bash-commit-push-preflight" "${2:-unknown}" "$1"
  cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"$1"}}
EOF
  exit 0
}

if [ "$IS_COMMIT" -eq 1 ] && [ -f "$(dirname "$0")/require-baseline-anchor-fresh.sh" ]; then
  BL_OUT=$(printf '%s' "$INPUT" | bash "$(dirname "$0")/require-baseline-anchor-fresh.sh" 2>/dev/null || true)
  if [ -n "$BL_OUT" ] && printf '%s' "$BL_OUT" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
    aal_log_denial "bash-commit-push-preflight" "require-baseline-anchor-fresh" "baseline anchor drift"
    printf '%s' "$BL_OUT"
    exit 0
  fi
fi

REPO=$(printf '%s' "$COMMAND" | sed -n 's/.*\bcd[[:space:]]\{1,\}\([^ &;|]\{1,\}\).*/\1/p' 2>/dev/null | head -1 || true)
[ -n "${REPO:-}" ] || REPO=$(json_get "$INPUT" cwd 2>/dev/null || echo "")
[ -n "${REPO:-}" ] || REPO="."
if ! git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  emit_deny "BLOCKED: the git repository cannot be resolved (neither the cd target nor payload.cwd is a working tree), so the red-line check over .claude and cleaned data is BLIND and this has to be refused. Write it as: \`cd /z/<your-checkout> && git add … && git commit …\` (its own command, with an explicit cd)." "repo-unresolvable"
fi

if git -C "$REPO" diff --cached --name-only 2>/dev/null | grep -q '^\.claude/'; then
  emit_deny "BLOCKED: .claude/ directory is staged. Run: git reset HEAD .claude/ — NEVER push .claude/ to GitHub." "claude-dir-staged"
fi

BAD_PATTERN='(^|/)(canonical[^/]*\.json$|cleaned/|published/|snapshots/|.*\.dump$|.*\.sql\.gz$|.*\.parquet$|.*\.ndjson$|apps/worker/public-data/|data-pipeline/data/v1/)'
if [ "$IS_COMMIT" -eq 1 ]; then
  CHANGED=$(git -C "$REPO" diff --cached --name-only 2>/dev/null || echo "")
  SCOPE="commit (staged)"
else
  BASE_REF="origin/main"
  git -C "$REPO" rev-parse --verify "$BASE_REF" >/dev/null 2>&1 || BASE_REF="main"
  CHANGED=$(git -C "$REPO" diff "$BASE_REF...HEAD" --name-only 2>/dev/null || echo "")
  SCOPE="push ($BASE_REF...HEAD)"
fi
if [ -n "$CHANGED" ]; then
  BLOCKED=$(echo "$CHANGED" | grep -E "$BAD_PATTERN" || true)
  if [ -n "$BLOCKED" ]; then
    PREVIEW=$(echo "$BLOCKED" | head -5 | tr '\n' ',' | sed 's/,$//')
    COUNT=$(echo "$BLOCKED" | wc -l)
    emit_deny "BLOCKED $SCOPE: includes cleaned/canonical data ($COUNT file(s)): $PREVIEW. Cleaned records, snapshots, DB dumps, and exported partitions are NOT open data. For commit: unstage with 'git restore --staged <path>'. For push: rewrite history to drop the file ('git rebase -i' + drop commits, OR 'git filter-repo'). If truly open data with license, bypass requires user '!' exec." "cleaned-data-commit"
  fi
fi

if [ "$IS_COMMIT" -eq 1 ]; then
  if echo "$COMMAND" | grep -qi 'Co-Authored-By'; then
    emit_deny "BLOCKED: Co-Authored-By line detected in commit message. Remove it — this is a hard rule." "coauthor-trailer"
  fi

  MSG=$(printf '%s' "$COMMAND" | grep -oE '(^|[[:space:]])-m[[:space:]]*"[^"]*"' | head -1 | sed 's/^[[:space:]]*-m[[:space:]]*"//; s/"$//' || echo "")
  if [ -z "$MSG" ]; then
    MSG=$(printf '%s' "$COMMAND" | grep -oE "(^|[[:space:]])-m[[:space:]]*'[^']*'" | head -1 | sed "s/^[[:space:]]*-m[[:space:]]*'//; s/'\$//" || echo "")
  fi
  if [ -z "$MSG" ]; then
    MSG=$(echo "$COMMAND" | sed -n 's/.*-m.*<<.*EOF[[:space:]]*//p' | head -1 || echo "")
  fi
  if [ -n "$MSG" ]; then
    case "$MSG" in
      '$('*|'cat <<'*|'`'*) ;;
      *)
        if ! echo "$MSG" | grep -qE '^(feat|fix|refactor|docs|test|chore|perf|ci|build|style)(\([^)]+\))?!?:[[:space:]]'; then
          emit_deny "BLOCKED: Commit message must follow conventional format: <type>(optional-scope)!?: <description>. Allowed types: feat|fix|refactor|docs|test|chore|perf|ci|build|style. Examples: 'feat: ...', 'fix(api): ...', 'refactor(web)!: breaking change'." "conventional-format"
        fi
        ;;
    esac
  fi
fi

exit 0

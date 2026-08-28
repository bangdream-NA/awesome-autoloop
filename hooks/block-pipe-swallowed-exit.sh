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

grep -qE '\|[[:space:]]*(head|tail|wc)\b' <<<"$COMMAND" || exit 0

case "$COMMAND" in *'# PIPE-EXIT-OK'*) exit 0;; esac
case "$COMMAND" in *'<<'*) exit 0;; esac
case "$COMMAND" in *pipefail*) exit 0;; esac

HIT=0
if grep -qE '\|[[:space:]]*(head|tail|wc)\b[^|;&<>)]*&&' <<<"$COMMAND"; then HIT=1; fi
if grep -qE '\|[[:space:]]*(head|tail|wc)\b[^|;&)]*;[[:space:]]*(echo|printf)[^;]*\$\?' <<<"$COMMAND"; then HIT=1; fi
if grep -qE '(^|[;&|(][[:space:]]*)((bash|sh)[[:space:]]+[^|;&]*\.sh\b|\./[^[:space:]|;&]*\.sh\b|git[[:space:]]+(push|merge|pull|rebase)\b|gh[[:space:]]+(pr[[:space:]]+(merge|create)|workflow[[:space:]]+run)\b)' <<<"$COMMAND"; then HIT=1; fi
[ "$HIT" = 1 ] || exit 0

REASON='BLOCKED: PIPE-SWALLOWED-EXIT. A pipeline into head/tail/wc, then && or $? used to judge success — that is the exit code of the LAST stage, not of the command doing the work. FIX, one of three: (1) judge the RESULT STATE instead (`test -f` / `[ -d ]` / `gh pr view --json state`); (2) run it without the pipe, capture `rc=$?` on its own, and truncate the output afterwards; (3) prefix `set -o pipefail`. Exemption: append `# PIPE-EXIT-OK`.'

aal_log_denial "bash-cmd-quality-preflight" "block-pipe-swallowed-exit" "pipe-to-truncator judged by &&/\$?" || true

printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}' \
  "$(printf '%s' "$REASON" | sed 's/\\/\\\\/g; s/"/\\"/g')"
exit 0

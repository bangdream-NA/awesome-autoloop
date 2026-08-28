#!/usr/bin/env bash
set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":ledger-hygiene:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
source "$(dirname "$0")/lib/parse-json.sh"
aal_have_node || exit 0
INPUT=$(cat)

STOP_ACTIVE=$(json_get "$INPUT" stop_hook_active)
[ "$STOP_ACTIVE" = "true" ] && exit 0

THRESHOLD="${LEDGER_GUARD_THRESHOLD:-245760}"

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || echo "")}"
LEDGERS=""
if [ -n "$PROJECT_DIR" ]; then
  LEDGERS="$PROJECT_DIR/.claude/BACKLOG.md
$PROJECT_DIR/.claude/code-reviews.md
$PROJECT_DIR/.claude/plan-reviews.md
$PROJECT_DIR/.claude/reviews/index.jsonl
$PROJECT_DIR/.claude/struggle-log.md"
fi
LEDGERS="$LEDGERS
${CLAUDE_CONFIG_DIR:-$HOME/.claude}/struggle-log.md"

OVER=""
IFS='
'
for f in $LEDGERS; do
  [ -f "$f" ] || continue
  b=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
  case "$b" in (*[!0-9]*|'') b=0 ;; esac
  if [ "$b" -gt "$THRESHOLD" ]; then
    OVER="$OVER $(basename "$f")=$((b/1024))KB"
  fi
done
unset IFS

[ -z "$OVER" ] && exit 0

WINDOW="${LEDGER_GUARD_THROTTLE_SECS:-900}"
SESSION_ID=$(json_get "$INPUT" session_id)
STATE_DIR="${CLAUDE_PLUGIN_DATA:-${TMPDIR:-/tmp}}/aal-state"
mkdir -p "$STATE_DIR" 2>/dev/null || true
STATE_FILE="$STATE_DIR/ledger-size-guard-${SESSION_ID:-global}.last"
NOW=$(date +%s)
if [ -f "$STATE_FILE" ]; then
  LAST=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
  case "$LAST" in (*[!0-9]*|'') LAST=0 ;; esac
  [ $((NOW - LAST)) -lt "$WINDOW" ] && exit 0
fi
echo "$NOW" > "$STATE_FILE" 2>/dev/null || true
find "$STATE_DIR" -name 'ledger-size-guard-*.last' -mtime +2 -delete 2>/dev/null || true

REASON="Ledger size guard. These session ledgers exceed 240KB and risk the 256KB Read-tool ceiling (a ledger you cannot Read is a ledger you cannot enforce):$OVER. SPLIT each at line boundaries into <name>-archive-NN.md (each <240KB, ALL content preserved + Read-able) and replace the active file with a short header listing the parts; new entries append to the fresh active file (gate hooks grep the ACTIVE file, so recent verdicts stay found). NEVER truncate or discard content. Then stop."
ESCAPED=$(printf '%s' "$REASON" | sed 's/\\/\\\\/g; s/"/\\"/g')
printf '{"decision":"block","reason":"%s","systemMessage":"ledger size guard","suppressOutput":true}\n' "$ESCAPED"
exit 0

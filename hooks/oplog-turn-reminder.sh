#!/usr/bin/env bash
set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":pipeline-roles:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
source "$(dirname "$0")/lib/parse-json.sh"
aal_have_node || exit 0
INPUT=$(cat)

STOP_ACTIVE=$(json_get "$INPUT" stop_hook_active)
[ "$STOP_ACTIVE" = "true" ] && exit 0

PROJ="$(aal_resolve_project_dir)"

SESSION_ID=$(json_get "$INPUT" session_id)
MY_SID8=$(printf '%s' "$SESSION_ID" | tr -cd 'A-Za-z0-9' | cut -c1-8 | tr 'A-Z' 'a-z')
[ "${#MY_SID8}" -eq 8 ] || MY_SID8=""

SID_RE='^autoloop-log-[0-9]{4}-[0-9]{2}-[0-9]{2}(-[0-9]{6})?-[0-9a-z]{8}\.md$'
OWN=""; OWN_KEY=""; LEG=""; LEG_KEY=""
for f in "$PROJ"/.claude/autoloop-log-*.md; do
  [ -f "$f" ] || continue
  b=$(basename "$f")
  case "$b" in (*archive*) continue ;; esac
  if printf '%s' "$b" | grep -qE "$SID_RE"; then
    sid=$(printf '%s' "$b" | sed -E 's/^.*-([0-9a-z]{8})\.md$/\1/')
    { [ -n "$MY_SID8" ] && [ "$sid" = "$MY_SID8" ]; } || continue
    key=$(printf '%s' "$b" | sed -E 's/-[0-9a-z]{8}\.md$//' | tr -cd '0-9')
    if [ -z "$OWN" ] || [ "$key" \> "$OWN_KEY" ]; then OWN="$f"; OWN_KEY="$key"; fi
  else
    key=$(printf '%s' "$b" | tr -cd '0-9')
    if [ -z "$LEG" ] || [ "$key" \> "$LEG_KEY" ]; then LEG="$f"; LEG_KEY="$key"; fi
  fi
done
rotate_if_big() {
  local file="$1" suffix="$2"
  { [ -n "$file" ] && [ -f "$file" ]; } || return 0
  local bytes; bytes=$(wc -c < "$file" 2>/dev/null | tr -d ' '); case "$bytes" in (*[!0-9]*|'') bytes=0 ;; esac
  [ "$bytes" -gt 250000 ] || return 0
  local new
  new="$PROJ/.claude/autoloop-log-$(date +%Y-%m-%d-%H%M%S)${suffix}.md"
  [ -e "$new" ] && return 0
  printf '# Autoloop op-log (rotated %s)\n\n> Previous %s frozen at %s bytes (Read-able, <256KB). Append new rows here.\n\n' \
    "$(date -u +%FT%TZ)" "$(basename "$file")" "$bytes" > "$new" 2>/dev/null || true
}
rotate_if_big "$OWN" "-$MY_SID8"
rotate_if_big "$LEG" ""
[ -n "$OWN" ] || [ -n "$LEG" ] || exit 0

WINDOW="${OPLOG_REMINDER_THROTTLE_SECS:-1200}"
STATE_DIR="${CLAUDE_PLUGIN_DATA:-${TMPDIR:-/tmp}}/aal-state"
mkdir -p "$STATE_DIR" 2>/dev/null || true
STATE_FILE="$STATE_DIR/oplog-reminder-${SESSION_ID:-global}.last"
NOW=$(date +%s)
if [ -f "$STATE_FILE" ]; then
  LAST=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
  case "$LAST" in (*[!0-9]*|'') LAST=0 ;; esac
  if [ $((NOW - LAST)) -lt "$WINDOW" ]; then
    exit 0
  fi
fi
echo "$NOW" > "$STATE_FILE" 2>/dev/null || true
find "$STATE_DIR" -name 'oplog-reminder-*.last' -mtime +2 -delete 2>/dev/null || true

cat <<'EOF'
{"decision":"block","reason":"Op-log ledger check. Default SKIP. Did this turn (or turns since the last op-log write) produce a LEDGER-WORTHY action NOT yet in the active project's autoloop op-log (.claude/autoloop-log-*.md) — a merge / deploy / republish / server-op, an agent dispatch or wave state-change, a decision / blocker / live-finding? If YES: append ONE concise row (feature·problem·proof, or action·result·next) to the project's LATEST autoloop-log-*.md, then stop. If purely conversational / read-only / already-logged: stop immediately with NO commentary. (Merges are separately HARD-gated by require-oplog-row-for-this-merge.sh — this backstop only catches the between-merge actions that gate cannot see.)","systemMessage":"op-log ledger check","suppressOutput":true}
EOF
exit 0

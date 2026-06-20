#!/usr/bin/env bash
# oplog-turn-reminder.sh — Stop check (consolidated via stop-dispatcher.sh): turn-end nudge to keep
# the autoloop op-log ledger current.
#
# Complements require-oplog-row-for-this-merge.sh (which HARD-gates `gh pr merge`): THIS catches the
# BETWEEN-merge ledger-worthy actions the merge-gate cannot see — server-ops/republish, agent
# dispatches, wave state-changes, decisions/blockers/findings.
#
# Mirrors session-learnings.sh: loop-guard (stop_hook_active → fire once per turn) + per-session
# throttle (default 1200s, tunable via OPLOG_REMINDER_THROTTLE_SECS). No-op unless the autoloop
# op-log convention exists in THIS project. Resolves ONE project (the active one) — never scans
# across projects.
set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":pipeline-roles:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
source "$(dirname "$0")/lib/parse-json.sh"
aal_have_node || exit 0   # fail-OPEN: a turn-end reminder must not block on a node-less box
INPUT=$(cat)

# --- Loop guard: if we already blocked once this turn, let the model stop. ---
STOP_ACTIVE=$(json_get "$INPUT" stop_hook_active)
[ "$STOP_ACTIVE" = "true" ] && exit 0

# --- No-op unless THIS project uses the autoloop op-log convention. Resolve ONE project. ---
PROJ="$(aal_resolve_project_dir)"
OPLOG=$(ls -t "$PROJ"/.claude/autoloop-log-*.md 2>/dev/null | head -1 || true)
[ -n "$OPLOG" ] || exit 0

# --- Auto-rotate: keep the active op-log under the 256KB Read-tool ceiling. When it crosses ~250KB,
#     start a fresh dated copy IN THE PROJECT DIR so it is always Read-able; the just-frozen file
#     stays put (<256KB) as history. The new file has the newest mtime so the gate hooks resolve it
#     as the project's LATEST automatically. Only the NEWEST (active) file is considered — frozen
#     historical files >250KB must never re-trigger rotation. ---
if [ -f "$OPLOG" ]; then
  LOG_BYTES=$(wc -c < "$OPLOG" 2>/dev/null | tr -d ' ')
  case "$LOG_BYTES" in (*[!0-9]*|'') LOG_BYTES=0 ;; esac
  if [ "$LOG_BYTES" -gt 250000 ]; then
    NEWLOG="$PROJ/.claude/autoloop-log-$(date +%Y-%m-%d-%H%M%S).md"
    if [ ! -e "$NEWLOG" ]; then
      printf '# Autoloop op-log (rotated %s)\n\n> Previous %s frozen at %s bytes (Read-able, <256KB). Append new rows here.\n\n' \
        "$(date -u +%FT%TZ)" "$(basename "$OPLOG")" "$LOG_BYTES" > "$NEWLOG" 2>/dev/null || true
    fi
  fi
fi

# --- Throttle: fire at most once per WINDOW per session. ---
WINDOW="${OPLOG_REMINDER_THROTTLE_SECS:-1200}"
SESSION_ID=$(json_get "$INPUT" session_id)
STATE_DIR="${CLAUDE_PLUGIN_DATA:-${TMPDIR:-/tmp}}/aal-state"
mkdir -p "$STATE_DIR" 2>/dev/null || true
STATE_FILE="$STATE_DIR/oplog-reminder-${SESSION_ID:-global}.last"
NOW=$(date +%s)
if [ -f "$STATE_FILE" ]; then
  LAST=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
  case "$LAST" in (*[!0-9]*|'') LAST=0 ;; esac
  if [ $((NOW - LAST)) -lt "$WINDOW" ]; then
    exit 0   # within throttle window — let the model stop quietly
  fi
fi
echo "$NOW" > "$STATE_FILE" 2>/dev/null || true
find "$STATE_DIR" -name 'oplog-reminder-*.last' -mtime +2 -delete 2>/dev/null || true

# --- Emit the turn-end op-log ledger directive (decision:block + reason). ---
cat <<'EOF'
{"decision":"block","reason":"Op-log ledger check. Default SKIP. Did this turn (or turns since the last op-log write) produce a LEDGER-WORTHY action NOT yet in the active project's autoloop op-log (.claude/autoloop-log-*.md) — a merge / deploy / republish / server-op, an agent dispatch or wave state-change, a decision / blocker / live-finding? If YES: append ONE concise row (feature·problem·proof, or action·result·next) to the project's LATEST autoloop-log-*.md, then stop. If purely conversational / read-only / already-logged: stop immediately with NO commentary. (Merges are separately HARD-gated by require-oplog-row-for-this-merge.sh — this backstop only catches the between-merge actions that gate cannot see.)","systemMessage":"op-log ledger check","suppressOutput":true}
EOF
exit 0

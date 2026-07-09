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

# --- Session identity for the two-class rotation model. MY_SID8 = first 8 alphanumeric chars of the
#     session_id, lowercased. Under the per-session model each session appends to its OWN
#     autoloop-log-<date>-<sid8>.md, so a session must rotate ONLY its own ledger, never another
#     session's (shared-append corruption is what this fixes). <8 alnum → class-1 (own per-session
#     ledger) DISABLED; only class-2 (legacy shared) runs (AC-O4, no crash). ---
SESSION_ID=$(json_get "$INPUT" session_id)
MY_SID8=$(printf '%s' "$SESSION_ID" | tr -cd 'A-Za-z0-9' | cut -c1-8 | tr 'A-Z' 'a-z')
[ "${#MY_SID8}" -eq 8 ] || MY_SID8=""

# --- Two-class active-op-log resolution + rotation. A file is SESSION-OWNED (sid8) iff its basename
#     matches a complete date, an optional -HHMMSS, then a trailing 8-char lowercase-alnum sid:
#     autoloop-log-YYYY-MM-DD[-HHMMSS]-<sid8>.md. Legacy names (…-YYYY-MM-DD.md, …-HHMMSS.md,
#     autoloop-log-TEMPLATE.md) have NO trailing 8-char sid segment after the date → NOT sid8-owned
#     (a legacy -HHMMSS timestamp is 6 digits, never 8, so the classes never collide).
#   Class 1 (own): among files whose trailing sid == MY_SID8, the FILENAME-DIGIT-max one is my active
#     ledger. Filename date-digits are append-proof + monotonic (a session APPENDING bumps mtime, so
#     `ls -t` would re-pick the OLD oversized file and churn stubs — the digit-key avoids that).
#   Class 2 (legacy): among files that are NOT sid8-owned (and not *archive*), the SAME filename-digit
#     -max logic picks the active — byte-compatible with the pre-two-class behavior (existing rotation
#     cases stay GREEN). Only the resolved active file per class is size-checked.
#   SKIP: any sid8-owned file whose sid != MY_SID8 is NEVER size-checked or rotated.
SID_RE='^autoloop-log-[0-9]{4}-[0-9]{2}-[0-9]{2}(-[0-9]{6})?-[0-9a-z]{8}\.md$'
OWN=""; OWN_KEY=""; LEG=""; LEG_KEY=""
for f in "$PROJ"/.claude/autoloop-log-*.md; do
  [ -f "$f" ] || continue
  b=$(basename "$f")
  case "$b" in (*archive*) continue ;; esac
  if printf '%s' "$b" | grep -qE "$SID_RE"; then
    sid=$(printf '%s' "$b" | sed -E 's/^.*-([0-9a-z]{8})\.md$/\1/')
    { [ -n "$MY_SID8" ] && [ "$sid" = "$MY_SID8" ]; } || continue   # skip other sessions' (+ class-1-off skips all sid files)
    # Key off the date[-HHMMSS] ONLY — STRIP the trailing -<sid8> first. All own files share the same
    # sid8, and its digits (e.g. a1b2c3d4 → "1234") would otherwise pollute the compare: the bare
    # `autoloop-log-<date>-<sid8>.md` key "date+sid" would beat its own `-<HHMMSS>-<sid8>` successor
    # whenever sid's leading digit > HHMMSS's, re-picking the oversized original every turn = the churn
    # the digit-key exists to prevent. Stripped, the key is date[+HHMMSS] digits, monotonic like the
    # legacy class (a same-day timestamped successor's longer same-prefix key wins).
    key=$(printf '%s' "$b" | sed -E 's/-[0-9a-z]{8}\.md$//' | tr -cd '0-9')
    if [ -z "$OWN" ] || [ "$key" \> "$OWN_KEY" ]; then OWN="$f"; OWN_KEY="$key"; fi
  else
    key=$(printf '%s' "$b" | tr -cd '0-9')
    if [ -z "$LEG" ] || [ "$key" \> "$LEG_KEY" ]; then LEG="$f"; LEG_KEY="$key"; fi
  fi
done
# Rotate an active file when it crosses ~250KB: mint a fresh dated successor IN THE PROJECT DIR (always
# Read-able); the frozen file stays put as history. The successor's date-digits are the largest, so the
# next turn's resolution picks it. Own ledger → same-sid8 successor; legacy → un-suffixed (existing shape).
rotate_if_big() {  # <active-file> <successor-suffix-or-empty>
  local file="$1" suffix="$2"
  { [ -n "$file" ] && [ -f "$file" ]; } || return 0
  local bytes; bytes=$(wc -c < "$file" 2>/dev/null | tr -d ' '); case "$bytes" in (*[!0-9]*|'') bytes=0 ;; esac
  [ "$bytes" -gt 250000 ] || return 0
  local new="$PROJ/.claude/autoloop-log-$(date +%Y-%m-%d-%H%M%S)${suffix}.md"
  [ -e "$new" ] && return 0
  printf '# Autoloop op-log (rotated %s)\n\n> Previous %s frozen at %s bytes (Read-able, <256KB). Append new rows here.\n\n' \
    "$(date -u +%FT%TZ)" "$(basename "$file")" "$bytes" > "$new" 2>/dev/null || true
}
rotate_if_big "$OWN" "-$MY_SID8"
rotate_if_big "$LEG" ""
[ -n "$OWN" ] || [ -n "$LEG" ] || exit 0

# --- Throttle: fire at most once per WINDOW per session. (SESSION_ID resolved above.) ---
WINDOW="${OPLOG_REMINDER_THROTTLE_SECS:-1200}"
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

#!/usr/bin/env bash
set -eu
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":pipeline-roles:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
source "$(dirname "$0")/lib/parse-json.sh"
aal_have_node || exit 0
INPUT=$(cat 2>/dev/null || echo '{}')
TEAMS_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/teams"
[ -d "$TEAMS_DIR" ] || exit 0
CAP="${AAL_ROSTER_TRIPWIRE:-11}"

find "$TEAMS_DIR" -maxdepth 1 -type d -mtime +2 2>/dev/null | while IFS= read -r d; do
  [ "$d" = "$TEAMS_DIR" ] && continue
  rm -rf "$d" 2>/dev/null || true
done

SESSION_ID=$(json_get "$INPUT" session_id 2>/dev/null || echo global)

MAX=0; BIG=""
for cfg in "$TEAMS_DIR"/*/config.json; do
  [ -f "$cfg" ] || continue
  owner=$(node -e 'try{process.stdout.write(String((require(process.argv[1]).leadSessionId)||""))}catch(e){}' "$cfg" 2>/dev/null)
  if [ "$SESSION_ID" != "global" ] && [ -n "$owner" ]; then case "$owner" in "$SESSION_ID"*) : ;; *) continue ;; esac; fi
  n=$(node -e 'try{const j=require(process.argv[1]);console.log((j.members||[]).length)}catch(e){console.log(0)}' "$cfg" 2>/dev/null)
  case "$n" in (*[!0-9]*|'') n=0 ;; esac
  if [ "$n" -gt "$MAX" ]; then MAX="$n"; BIG=$(basename "$(dirname "$cfg")"); fi
done

if [ "$MAX" -gt "$CAP" ]; then
  msg="roster tripwire: team ${BIG} has ${MAX} members (cap ${CAP}). With shutdown-on-accept each live wave needs ~1 agent, so a roster this large means done/idle agents were never shut down. IMPORTANT: this hook scans ALL teams under ~/.claude/teams — if team ${BIG} is NOT this session's team, do NOTHING (another live session owns it; cross-session shutdowns are forbidden). Only if it IS yours: SendMessage a shutdown_request to each whose deliverable is already accepted (merged PR / APPROVED review / handed-off spec) — config.json members PRUNE on shutdown, freeing slots and avoiding the spawn/TeamDelete catch-22."
  WINDOW="${ROSTER_TRIPWIRE_THROTTLE_SECS:-1800}"
  STATE_DIR="${CLAUDE_PLUGIN_DATA:-${TMPDIR:-/tmp}}/aal-state"
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  TKEY=$(printf '%s' "$BIG" | tr -c 'A-Za-z0-9' _)
  STATE_FILE="$STATE_DIR/roster-tripwire-${SESSION_ID:-global}-${TKEY}.last"
  NOW=$(date +%s)
  if [ -f "$STATE_FILE" ]; then
    LAST=$(cat "$STATE_FILE" 2>/dev/null || echo 0); case "$LAST" in (*[!0-9]*|'') LAST=0 ;; esac
    [ $((NOW - LAST)) -lt "$WINDOW" ] && exit 0
  fi
  echo "$NOW" > "$STATE_FILE" 2>/dev/null || true
  find "$STATE_DIR" -name 'roster-tripwire-*.last' -mtime +2 -delete 2>/dev/null || true
  printf '{"systemMessage":"%s"}' "$(printf '%s' "$msg" | sed 's/\\/\\\\/g; s/"/\\"/g')"
fi
exit 0

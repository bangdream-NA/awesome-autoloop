#!/usr/bin/env bash
# Stop hook — roster tripwire: warn when the live team roster piles up.
#
# With shutdown-on-deliverable-accept each in-flight wave occupies ~1 live agent (roles hand
# off + shut down), so a roster above the cap means done/idle agents were never shut down — a
# pile-up that can wedge dispatch (the spawn/TeamDelete catch-22). This Stop hook flags it.
# Silent unless over the cap. Tune via AAL_ROSTER_TRIPWIRE (default 11).
#
# (This is the SIMPLIFIED, project-agnostic member-count cap. A board-aware variant that also
# cross-references each member's wave-slug against an active task board — flagging the exact
# STALE agents to shut down — ships as examples/roster-board-aware.example.sh for users who adopt
# a board-card convention; it can't be generic without imposing a specific board-card format.)
set -eu
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":pipeline-roles:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
source "$(dirname "$0")/lib/parse-json.sh"
aal_have_node || exit 0
# Drain the Stop payload so the same-text throttle below can key on session_id (under the
# stop-dispatcher this hook is fed stdin; standalone it reads an empty payload → keys on 'global').
INPUT=$(cat 2>/dev/null || echo '{}')
TEAMS_DIR="$HOME/.claude/teams"
[ -d "$TEAMS_DIR" ] || exit 0
CAP="${AAL_ROSTER_TRIPWIRE:-11}"

# C-16: prune team dirs untouched >2 days (= dead sessions) so a stale pile-up doesn't
# trip a false roster warning. This Stop hook has no Agent payload → can't scope to one
# team; the stale-prune removes the false-positive source. Warn-only, so a residual
# over-count is benign.
find "$TEAMS_DIR" -maxdepth 1 -type d -mtime +2 2>/dev/null | while IFS= read -r d; do
  [ "$d" = "$TEAMS_DIR" ] && continue
  rm -rf "$d" 2>/dev/null || true
done

# biggest team by member count
MAX=0; BIG=""
for cfg in "$TEAMS_DIR"/*/config.json; do
  [ -f "$cfg" ] || continue
  n=$(node -e 'try{const j=require(process.argv[1]);console.log((j.members||[]).length)}catch(e){console.log(0)}' "$cfg" 2>/dev/null)
  case "$n" in (*[!0-9]*|'') n=0 ;; esac
  if [ "$n" -gt "$MAX" ]; then MAX="$n"; BIG=$(basename "$(dirname "$cfg")"); fi
done

if [ "$MAX" -gt "$CAP" ]; then
  msg="roster tripwire: team ${BIG} has ${MAX} members (cap ${CAP}). With shutdown-on-accept each live wave needs ~1 agent, so a roster this large means done/idle agents were never shut down. IMPORTANT: this hook scans ALL teams under ~/.claude/teams — if team ${BIG} is NOT this session's team, do NOTHING (another live session owns it; cross-session shutdowns are forbidden). Only if it IS yours: SendMessage a shutdown_request to each whose deliverable is already accepted (merged PR / APPROVED review / handed-off spec) — config.json members PRUNE on shutdown, freeing slots and avoiding the spawn/TeamDelete catch-22."
  # Same-text throttle (content-hashed, per session): an IDENTICAL warning within the window is
  # suppressed so a stuck-over-cap session doesn't re-warn every turn. A DIFFERENT warning (other
  # team/count → different text → different hash) still shows. Window matches check-stale-agents.
  SESSION_ID=$(json_get "$INPUT" session_id 2>/dev/null || echo global)
  WINDOW="${ROSTER_TRIPWIRE_THROTTLE_SECS:-1800}"
  STATE_DIR="${CLAUDE_PLUGIN_DATA:-${TMPDIR:-/tmp}}/aal-state"
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  HASH=$(printf '%s' "$msg" | cksum | awk '{print $1}')
  STATE_FILE="$STATE_DIR/roster-tripwire-${SESSION_ID:-global}-${HASH}.last"
  NOW=$(date +%s)
  if [ -f "$STATE_FILE" ]; then
    LAST=$(cat "$STATE_FILE" 2>/dev/null || echo 0); case "$LAST" in (*[!0-9]*|'') LAST=0 ;; esac
    [ $((NOW - LAST)) -lt "$WINDOW" ] && exit 0   # identical warn within window → suppress
  fi
  echo "$NOW" > "$STATE_FILE" 2>/dev/null || true
  find "$STATE_DIR" -name 'roster-tripwire-*.last' -mtime +2 -delete 2>/dev/null || true
  printf '{"systemMessage":"%s"}' "$(printf '%s' "$msg" | sed 's/\\/\\\\/g; s/"/\\"/g')"
fi
exit 0

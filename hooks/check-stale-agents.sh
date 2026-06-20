#!/usr/bin/env bash
# check-stale-agents.sh — Stop hook backstop.
#
# Codifies the "team-lead must check idle teammates every ~30min" constraint.
# Backstops the failure mode: agents go idle without sending a delivery, no artifact
# lands, the lead doesn't notice → wasted time.
#
# Mechanism: at every turn-end (Stop), find the team this session is leading,
# list non-lead members, check each member's inbox file mtime (last time the
# LEAD messaged them — proxy for "still being driven"). If a member's inbox
# is >30min old AND the member is still listed alive, flag with decision:block.
#
# LOOP GUARD: like session-learnings.sh, we honor stop_hook_active to fire once
# per turn. Combined with the natural force-stop after N consecutive blocks,
# this can't infinite-loop the agent.
#
# THROTTLE: per-session window (default 1800s = 30min) so a single warned
# stale-agent doesn't refire every turn.

set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":pipeline-roles:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0

source "$(dirname "$0")/lib/parse-json.sh"
aal_have_node || exit 0

INPUT=$(cat)

# Loop guard
STOP_ACTIVE=$(json_get "$INPUT" stop_hook_active)
[ "$STOP_ACTIVE" = "true" ] && exit 0

SESSION_ID=$(json_get "$INPUT" session_id)
[ -z "$SESSION_ID" ] && exit 0

# Throttle per session
WINDOW="${STALE_AGENTS_THROTTLE_SECS:-1800}"
STATE_DIR="${CLAUDE_PLUGIN_DATA:-${TMPDIR:-/tmp}}/aal-state"
mkdir -p "$STATE_DIR" 2>/dev/null || true
STATE_FILE="$STATE_DIR/check-stale-agents-${SESSION_ID}.last"
NOW=$(date +%s)
if [ -f "$STATE_FILE" ]; then
  LAST=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
  case "$LAST" in (*[!0-9]*|'') LAST=0 ;; esac
  if [ $((NOW - LAST)) -lt "$WINDOW" ]; then exit 0; fi
fi

# Find the team this session leads
TEAM_DIR=""
for cfg in "$HOME"/.claude/teams/*/config.json; do
  [ -f "$cfg" ] || continue
  if grep -q "\"leadSessionId\"[[:space:]]*:[[:space:]]*\"$SESSION_ID\"" "$cfg" 2>/dev/null; then
    TEAM_DIR=$(dirname "$cfg")
    break
  fi
done
[ -z "$TEAM_DIR" ] && exit 0

MEMBERS_FILE="$TEAM_DIR/config.json"
INBOX_DIR="$TEAM_DIR/inboxes"
[ -d "$INBOX_DIR" ] || exit 0

# Non-lead members + their inbox mtimes
THRESHOLD=$((30*60))
STALE=""
COUNT=0
while IFS= read -r name; do
  [ -z "$name" ] && continue
  INBOX_FILE="$INBOX_DIR/${name}.json"
  if [ ! -f "$INBOX_FILE" ]; then continue; fi
  MTIME=$(stat -c %Y "$INBOX_FILE" 2>/dev/null || stat -f %m "$INBOX_FILE" 2>/dev/null || echo 0)
  case "$MTIME" in (*[!0-9]*|'') MTIME=0 ;; esac
  AGE=$((NOW - MTIME))
  if [ "$AGE" -gt "$THRESHOLD" ]; then
    MIN=$((AGE / 60))
    STALE="$STALE ${name}(${MIN}min)"
    COUNT=$((COUNT + 1))
  fi
done < <(node -e 'try{const c=require(process.argv[1]);(c.members||[]).filter(m=>(m.agentType||"")!=="team-lead").forEach(m=>process.stdout.write((m.name||"")+"\n"))}catch{}' "$MEMBERS_FILE" 2>/dev/null)

if [ "$COUNT" = "0" ]; then exit 0; fi

echo "$NOW" > "$STATE_FILE" 2>/dev/null || true
find "$STATE_DIR" -name 'check-stale-agents-*.last' -mtime +2 -delete 2>/dev/null || true

REASON="check-stale-agents: ${COUNT} alive teammate(s) have inbox files older than 30min — they may have gone idle without delivering. Stale list (last lead-→-agent message age):${STALE}. BEFORE stopping this turn: (a) confirm each agent's delivery actually landed (verify the expected artifact on disk — JSONL line, spec file, PR, etc.); (b) ping any that have NOT delivered with a status SendMessage; (c) if a ping was already sent within this window and still no reply, shutdown_request + respawn fresh. Then stop."

cat <<EOF
{"decision":"block","reason":$(printf '%s' "$REASON" | node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(s)));'),"systemMessage":"stale-agent check: ${COUNT} idle >30min","suppressOutput":false}
EOF
exit 0

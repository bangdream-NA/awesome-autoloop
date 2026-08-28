#!/usr/bin/env bash
TEAMS_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/teams"
BOARDS="${AAL_BOARDS:-<your-board-1>/.claude/BACKLOG.md;<your-board-2>/.claude/BACKLOG.md}"
[ -d "$TEAMS_DIR" ] || exit 0
CAP="${AAL_ROSTER_TRIPWIRE:-11}"

INPUT=$(cat 2>/dev/null || echo '{}')
SID=$(printf '%s' "$INPUT" | node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{try{process.stdout.write(String(JSON.parse(s).session_id||"nosid"))}catch{process.stdout.write("nosid")}})' 2>/dev/null || echo nosid)

MAX=0; CFGBIG=""; BIG=""
for cfg in "$TEAMS_DIR"/*/config.json; do
  [ -f "$cfg" ] || continue
  n=$(node -e 'try{const j=require(process.argv[1]);console.log((j.members||[]).length)}catch(e){console.log(0)}' "$cfg" 2>/dev/null)
  case "$n" in (*[!0-9]*|'') n=0 ;; esac
  if [ "$n" -gt "$MAX" ]; then MAX="$n"; BIG=$(basename "$(dirname "$cfg")"); CFGBIG="$cfg"; fi
done
[ -z "$CFGBIG" ] && exit 0

NAMES=$(node -e 'try{const j=require(process.argv[1]);console.log((j.members||[]).map(m=>m.name||m.id).filter(x=>x&&x!=="team-lead").join("\n"))}catch(e){console.log("")}' "$CFGBIG" 2>/dev/null)
[ -z "$NAMES" ] && exit 0

STALE=""; ACTIVE=""; UNKNOWN=""
while IFS= read -r m; do
  [ -z "$m" ] && continue
  slug=$(printf '%s' "$m" | sed -E 's/^(plan-reviewer|code-reviewer|planner|planrev|architect|arch|developer|dev|reviewer|designer|uiux)-//; s/^b[0-9]+[a-z]?-//')
  if [ "$slug" = "$m" ] || [ -z "$slug" ]; then
    UNKNOWN="$UNKNOWN $m"
    continue
  fi
  flex=$(printf '%s' "$slug" | sed 's/[^a-zA-Z0-9]//g; s/./&-\{0,1\}/g; s/-{0,1}$//')
  hit=0
  OLDIFS="$IFS"; IFS=';'
  for b in $BOARDS; do
    [ -f "$b" ] || continue
    if grep -qiE "$m" "$b" 2>/dev/null; then hit=1; break; fi
    if grep -qiE "^(### \[(IN-DEV|REVIEW|QUEUED|BLOCKED)\].*|- aliases:.*)${flex}" "$b" 2>/dev/null; then hit=1; break; fi
  done
  IFS="$OLDIFS"
  if [ "$hit" = "1" ]; then ACTIVE="$ACTIVE $m"; else STALE="$STALE $m"; fi
done <<EOF
$NAMES
EOF
STALE_N=$(printf '%s' "$STALE" | wc -w | tr -d ' ')

if [ "$MAX" -gt "$CAP" ] || [ "${STALE_N:-0}" -ge 2 ]; then
  msg="⚠ roster (board-aware): team ${BIG} has ${MAX} members (cap ${CAP}; ${STALE_N:-0} STALE). STALE candidates:${STALE:- (none)}. ACTIVE → keep:${ACTIVE:- (none)}.${UNKNOWN:+ UNKNOWN (no derivable wave-slug — judge by hand):${UNKNOWN}.} STALE = no active card / dispatch record for it on any known board. IMPORTANT: this hook scans ALL teams under ~/.claude/teams — if team ${BIG} is NOT this session's team, do NOTHING (another live session owns it; cross-session shutdowns are forbidden). Only if it IS yours: re-verify each STALE candidate first-hand (board + its recent activity), then SendMessage shutdown_request to the truly-done ones."
  HASH=$(printf '%s' "$msg" | cksum | cut -d' ' -f1)
  TDIR="${TMPDIR:-/tmp}/.roster-throttle"
  mkdir -p "$TDIR" 2>/dev/null || true
  TFILE="$TDIR/${SID}.${HASH}"
  if [ -f "$TFILE" ] && [ -n "$(find "$TFILE" -mmin -30 2>/dev/null)" ]; then exit 0; fi
  touch "$TFILE" 2>/dev/null || true
  find "$TDIR" -type f -mtime +2 -delete 2>/dev/null || true
  printf '{"systemMessage":"%s"}' "$(printf '%s' "$msg" | sed 's/\\/\\\\/g; s/"/\\"/g')"
fi
exit 0

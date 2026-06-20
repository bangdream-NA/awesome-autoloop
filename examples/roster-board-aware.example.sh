#!/usr/bin/env bash
# EXAMPLE (not mounted) — board-aware roster tripwire + STALE-agent flagging.
#
# The mounted hooks/roster-tripwire.sh is the SIMPLIFIED, project-agnostic member-COUNT cap. THIS
# variant additionally cross-references each live teammate's wave-slug against your ACTIVE task
# board(s) and flags the exact STALE agents (a member whose slug has NO active card) to shut down.
# It is an EXAMPLE because it must impose YOUR board-card format; the framework can't ship that
# generically. To adopt: copy to ~/.claude/hooks/roster-tripwire.sh (replacing the count-only one),
# set AAL_BOARDS to your board path(s), wire it on the Stop event (or via the stop-dispatcher CHECKS).
#
# Footgun fixes baked in (learned the hard way): full agent-name `grep -qiE` match FIRST (`-qiF`
# core-dumps on some MSYS grep builds; agent names are ERE-literal-safe); pure-alphanumeric per-char
# hyphen-flex (naming drifts hyphens: r7↔R-7, newsa11y↔news-a11y); SEMICOLON board separator (a
# colon would split a Windows drive-letter prefix like C: or D:); cross-session "do NOTHING" guard (the biggest team
# may belong to a CONCURRENT neighbor session you can't shut down); an UNKNOWN bucket for members
# whose wave-slug is not derivable (human judgment, never auto-"shut down NOW").
TEAMS_DIR="$HOME/.claude/teams"
# Multi-project boards: SEMICOLON-separated (a colon would split a Windows drive-letter prefix like C: or D:),
# overridable via AAL_BOARDS. A slug active on ANY board = ACTIVE.
BOARDS="${AAL_BOARDS:-<your-board-1>/.claude/BACKLOG.md;<your-board-2>/.claude/BACKLOG.md}"
[ -d "$TEAMS_DIR" ] || exit 0
CAP="${AAL_ROSTER_TRIPWIRE:-11}"

# stdin once (the stop-dispatcher feeds it): session_id keys the throttle.
INPUT=$(cat 2>/dev/null || echo '{}')
SID=$(printf '%s' "$INPUT" | node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{try{process.stdout.write(String(JSON.parse(s).session_id||"nosid"))}catch{process.stdout.write("nosid")}})' 2>/dev/null || echo nosid)

# biggest team by member count
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

# classify: ACTIVE if the member's wave-slug matches an active card (header or aliases/别名) on ANY
# board; STALE if a slug was derivable but matches nowhere; UNKNOWN if no slug was derivable.
STALE=""; ACTIVE=""; UNKNOWN=""
while IFS= read -r m; do
  [ -z "$m" ] && continue
  # strip role prefix, then an optional batch infix (b2-, r2b- style): dev-b2-r7 -> r7
  slug=$(printf '%s' "$m" | sed -E 's/^(plan-reviewer|code-reviewer|planner|planrev|architect|arch|developer|dev|reviewer|designer|uiux)-//; s/^b[0-9]+[a-z]?-//')
  if [ "$slug" = "$m" ] || [ -z "$slug" ]; then
    UNKNOWN="$UNKNOWN $m"   # un-derivable → human judgment, never auto-STALE
    continue
  fi
  # hyphen-flex normalization: naming drifts hyphens at ANY boundary (r7↔R-7, newsa11y↔news-a11y).
  # Strip the slug to pure alphanumerics (drops its own hyphens AND any regex metachars = no escaping
  # needed), then allow an optional hyphen between every char.
  flex=$(printf '%s' "$slug" | sed 's/[^a-zA-Z0-9]//g; s/./&-\{0,1\}/g; s/-{0,1}$//')
  hit=0
  OLDIFS="$IFS"; IFS=';'
  for b in $BOARDS; do
    [ -f "$b" ] || continue
    # STRONGEST signal first: the FULL agent name as a fixed string — board log rows record
    # dispatches verbatim ("派 planner-statichdr"), so a hit anywhere on the board = ACTIVE.
    # NOTE: -qiF core-dumps on some MSYS grep builds (even under LC_ALL=C) — use -qiE instead; agent
    # names ([A-Za-z0-9_-]) are ERE-literal-safe, and the -E path has never crashed here.
    if grep -qiE "$m" "$b" 2>/dev/null; then hit=1; break; fi
    if grep -qiE "^(### \[(IN-DEV|REVIEW|QUEUED|BLOCKED)\].*|- (aliases|别名)[:：].*)${flex}" "$b" 2>/dev/null; then hit=1; break; fi
  done
  IFS="$OLDIFS"
  if [ "$hit" = "1" ]; then ACTIVE="$ACTIVE $m"; else STALE="$STALE $m"; fi
done <<EOF
$NAMES
EOF
STALE_N=$(printf '%s' "$STALE" | wc -w | tr -d ' ')

if [ "$MAX" -gt "$CAP" ] || [ "${STALE_N:-0}" -ge 2 ]; then
  msg="⚠ roster (board-aware): team ${BIG} has ${MAX} members (cap ${CAP}; ${STALE_N:-0} STALE). STALE candidates:${STALE:- (none)}. ACTIVE → keep:${ACTIVE:- (none)}.${UNKNOWN:+ UNKNOWN (no derivable wave-slug — judge by hand):${UNKNOWN}.} STALE = no active card / dispatch record for it on any known board. IMPORTANT: this hook scans ALL teams under ~/.claude/teams — if team ${BIG} is NOT this session's team, do NOTHING (another live session owns it; cross-session shutdowns are forbidden). Only if it IS yours: re-verify each STALE candidate first-hand (board + its recent activity), then SendMessage shutdown_request to the truly-done ones."
  # same-text throttle: identical message suppressed for 30 min (content-hash + session keyed).
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

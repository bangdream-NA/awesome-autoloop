#!/usr/bin/env bash
# doctor-dispatched: session-learnings check-stale-agents prune-team-inboxes roster-tripwire ledger-size-guard worktree-count-guard check-unwalked-merges backlog-drift-check backlog-drift-guard oplog-turn-reminder render-finding-playwright-guard anomaly-recording-check
# ^ NOT a comment. skills/claude-doctor/doctor.sh reads this line to tell a hook that is DISPATCHED
# from here apart from one that is genuinely UNMOUNTED. Delete it and claude-doctor reports every
# check below as unmounted. Keep it in step with CHECKS.
set -uo pipefail
HOOKDIR="$(dirname "$0")"

INPUT=$(cat 2>/dev/null || echo '{}')

CHECKS=(
  session-learnings
  check-stale-agents
  prune-team-inboxes
  roster-tripwire
  ledger-size-guard
  worktree-count-guard
  check-unwalked-merges
  backlog-drift-check
  backlog-drift-guard
  oplog-turn-reminder
  render-finding-playwright-guard
  anomaly-recording-check
)

REASONS=""
WARNS=""
STATE_DIR="${CLAUDE_PLUGIN_DATA:-${TMPDIR:-/tmp}}/aal-state"
mkdir -p "$STATE_DIR" 2>/dev/null || true

for c in "${CHECKS[@]}"; do
  SCRIPT="$HOOKDIR/${c}.sh"
  [ -f "$SCRIPT" ] || continue
  (
    OUTF="$STATE_DIR/.disp-out.$$.$c"; ERRF="$STATE_DIR/.disp-err.$$.$c"; RCF="$STATE_DIR/.disp-rc.$$.$c"
    RC=0
    printf '%s' "$INPUT" | bash "$SCRIPT" >"$OUTF" 2>"$ERRF" || RC=$?
    printf '%s' "$RC" > "$RCF"
  ) &
done
wait 2>/dev/null || true

for c in "${CHECKS[@]}"; do
  SCRIPT="$HOOKDIR/${c}.sh"
  [ -f "$SCRIPT" ] || continue
  OUTF="$STATE_DIR/.disp-out.$$.$c"; ERRF="$STATE_DIR/.disp-err.$$.$c"; RCF="$STATE_DIR/.disp-rc.$$.$c"
  OUT=$(cat "$OUTF" 2>/dev/null || true)
  ERR=$(cat "$ERRF" 2>/dev/null || true)
  RC=$(cat "$RCF" 2>/dev/null || echo 0)
  rm -f "$OUTF" "$ERRF" "$RCF" 2>/dev/null || true

  if [ "$RC" = "2" ]; then
    [ -n "$ERR" ] && REASONS="${REASONS}${REASONS:+ | }${ERR}"
  elif [ -n "$OUT" ]; then
    PARSED=$(printf '%s' "$OUT" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>{try{const o=JSON.parse(d);process.stdout.write((o.decision==="block"&&o.reason?("R\t"+o.reason+"\n"):"")+(o.systemMessage?("W\t"+o.systemMessage+"\n"):""))}catch{}})' 2>/dev/null)
    while IFS=$'\t' read -r tag val; do
      [ "$tag" = "R" ] && [ -n "$val" ] && REASONS="${REASONS}${REASONS:+ | }${val}"
      [ "$tag" = "W" ] && [ -n "$val" ] && WARNS="${WARNS}${WARNS:+ | }${val}"
    done <<< "$PARSED"
  fi
done

ALL="$REASONS"
[ -n "$WARNS" ] && ALL="${ALL}${ALL:+ | }${WARNS}"
if [ -n "$ALL" ]; then
  node -e 'process.stdout.write(JSON.stringify({decision:"block",reason:process.argv[1]}))' "$ALL"
fi
exit 0

#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib/parse-json.sh" 2>/dev/null || true

INPUT=$(cat)
STOP_ACTIVE=$(printf '%s' "$INPUT" | node -e "let s='';process.stdin.on('data',c=>s+=c);process.stdin.on('end',()=>{try{process.stdout.write(String(JSON.parse(s).stop_hook_active||''))}catch{process.stdout.write('')}});" 2>/dev/null || echo "")
[ "$STOP_ACTIVE" = "true" ] && exit 0

BOARD="${GATE_AUDIT_BOARD:-<your-checkout>/.claude/BACKLOG.md}"
[ -f "$BOARD" ] || exit 0

WINDOW="${GATE_AUDIT_THROTTLE_SECS:-1800}"
SID=$(printf '%s' "$INPUT" | node -e "let s='';process.stdin.on('data',c=>s+=c);process.stdin.on('end',()=>{try{process.stdout.write(String(JSON.parse(s).session_id||'global'))}catch{process.stdout.write('global')}});" 2>/dev/null || echo "global")
STATE_DIR="$(dirname "$0")/.state"; STATE_FILE="$STATE_DIR/gate-audit-${SID}.last"
NOW=$(date +%s)
if [ -f "$STATE_FILE" ]; then
  LAST=$(cat "$STATE_FILE" 2>/dev/null || echo 0); case "$LAST" in (*[!0-9]*|'') LAST=0 ;; esac
  [ $((NOW - LAST)) -lt "$WINDOW" ] && exit 0
fi

GATED=$(node "$(dirname "$0")/lib/gated-cards-tsv.mjs" "$BOARD" 2>/dev/null || true)
[ -z "$GATED" ] && exit 0

MERGED_PRS=""
if command -v gh >/dev/null 2>&1; then
  MERGED_PRS=$( (cd "<your-checkout>" 2>/dev/null && gh pr list --state merged --limit 200 --json number --jq '.[].number' 2>/dev/null) || echo "")
fi
TODAY=$(date -u +%Y-%m-%d)

CLEARED=""
SUSPECT=""
while IFS= read -r line; do
  [ -z "$line" ] && continue
  slug=$(printf '%s' "$line" | cut -f2)
  status=$(printf '%s' "$line" | cut -f3)
  kind=$(printf '%s' "$line" | cut -f4)
  gate=$(printf '%s' "$line" | cut -f5)

  if [ "$kind" = "wave-gone" ]; then
    CLEARED="$CLEARED
  • $slug [$status] — the wave named by \`$gate\` is no longer an OPEN card → gate expired, OPEN it"
    continue
  fi
  [ "$kind" = "wave-live" ] && continue
  [ "$kind" = "user" ] && continue
  prref=$(printf '%s' "$gate" | grep -oiE 'blocked-by=(merge-order:|overlap:)?pr#[0-9]+|SEQUENCE-AFTER[^#]*#[0-9]+|(waiting|pending)[^#]*#[0-9]+[^#]*merge|#[0-9]+[^#]*merge[[:space:]]*(first|before)' | grep -oE '#[0-9]+' | head -1 | tr -d '#' || true)
  if [ -n "$prref" ]; then
    if printf '%s\n' "$MERGED_PRS" | grep -qx "$prref"; then
      CLEARED="$CLEARED
  • $slug — blocker PR #$prref is MERGED → gate cleared, OPEN it"
    fi
    continue
  fi
  datref=$(printf '%s' "$gate" | grep -oiE '(until|observe-until|through|by)[: ]?[0-9]{4}-[0-9]{2}-[0-9]{2}' | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1 || true)
  if [ -n "$datref" ]; then
    if [ "$TODAY" \> "$datref" ] || [ "$TODAY" = "$datref" ]; then
      CLEARED="$CLEARED
  • $slug — observe-window until $datref has PASSED (today $TODAY) → re-triage it"
    fi
    continue
  fi
  SUSPECT="$SUSPECT
  • $slug — the gate is not the one legal form. Only \`blocked-by=merge-order:pr#<N>\` exists now (this card's change cannot land before PR #N) -> either rewrite it as that, or DELETE the gate and leave the card open. \"It is not its turn yet\" is a priority order, not a gate."
done <<EOF
$GATED
EOF

[ -z "$CLEARED" ] && [ -z "$SUSPECT" ] && exit 0

mkdir -p "$STATE_DIR" 2>/dev/null || true; echo "$NOW" > "$STATE_FILE" 2>/dev/null || true
find "$STATE_DIR" -name 'gate-audit-*.last' -mtime +3 -delete 2>/dev/null || true

REASON="INDEPENDENT GATE REVIEW: every OPEN card's gate (QUEUED/IN-DEV/REVIEW/BLOCKED/USER-GATED) was checked against LIVE state by machine. Results:"
[ -n "$CLEARED" ] && REASON="$REASON

CLEARED BLOCKERS — these gates' stated blocker has provably resolved; they are ACTIONABLE NOW, open them this turn (phantom-verify per rule#9 first, then dispatch planner):$CLEARED"
[ -n "$SUSPECT" ] && REASON="$REASON

ABOLISHED GATES — only two legal gates remain: \`blocked-by=merge-order:pr#<N>\` and \`blocked-by=user · asked-at=<ISO Z>\`. The gates below are neither ⇒ rewrite them as one of those, or delete the gate and leave the card open. \`server-op\` / \`until:<date>\` / an observation window / \`overlap\` are all retired: $SUSPECT"
REASON="$REASON

Handle the above, then stop."

ESCAPED=$(printf '%s' "$REASON" | node -e "let s='';process.stdin.on('data',c=>s+=c);process.stdin.on('end',()=>{process.stdout.write(JSON.stringify(s))});" 2>/dev/null || printf '"gate audit"')
printf '{"decision":"block","reason":%s,"systemMessage":"independent gate review","suppressOutput":true}\n' "$ESCAPED"
exit 0

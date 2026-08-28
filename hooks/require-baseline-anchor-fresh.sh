#!/usr/bin/env bash
. "$(dirname "$0")/lib/log-denial.sh" 2>/dev/null || true
set -euo pipefail

PAYLOAD="$(cat)"

CWD="$(printf '%s' "$PAYLOAD" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const p=JSON.parse(s);process.stdout.write(p.cwd||"")}catch{}})' 2>/dev/null || true)"
[ -n "$CWD" ] || CWD="$PWD"
PROJECT="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$PROJECT" ] || exit 0

BASELINE="$PROJECT/scripts/__tests__/pipefail-sigpipe-baseline.txt"
LIB="$PROJECT/scripts/__tests__/lib/pipefail-sigpipe-baseline-lib.sh"

[ -f "$BASELINE" ] && [ -f "$LIB" ] || exit 0

COMMAND="$(printf '%s' "$PAYLOAD" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const p=JSON.parse(s);process.stdout.write((p.tool_input&&p.tool_input.command)||"")}catch{}})' 2>/dev/null || true)"
[ -n "$COMMAND" ] || exit 0

grep -qE '(^|[;&|]\s*)git\s+(commit|merge)\b' <<<"$COMMAND" || exit 0

# shellcheck source=/dev/null
. "$LIB"

stale=""
count=0
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  case "$entry" in \#*) continue ;; esac
  path="${entry%%:*}"
  rest="${entry#*:}"
  line="${rest%%:*}"
  rest="${rest#*:}"
  stored="${rest%% *}"
  [ -n "$path" ] && [ -n "$line" ] && [ -n "$stored" ] || continue
  count=$((count + 1))
  if ! live="$(compute_content_anchor "$PROJECT/$path" "$line" 2>/dev/null)"; then
    stale="${stale}
  ${path}:${line} — line is PAST EOF (file shrank above it)"
    continue
  fi
  if [ "$live" != "$stored" ]; then
    stale="${stale}
  ${path}:${line} — stored ${stored:0:12}… but that line now hashes ${live:0:12}…"
  fi
done < "$BASELINE"

[ -n "$stale" ] || exit 0

stale="$(printf '%s' "$stale" | sed ':a;N;$!ba;s/\n/\\n/g')"

  aal_log_denial "require-baseline-anchor-fresh" "site-1" "deny" 2>/dev/null || true
cat <<JSON
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: BASELINE ANCHOR DRIFT ($count entries checked) — a pinned line's hash does not match the stored anchor: $stale\n\nThis is almost always LINE DRIFT rather than a content change: you edited ABOVE the pinned line, so the line number now points somewhere else.\nFIX: grep for where that construct actually is now, edit the line NUMBER by hand (the digits only), then run the gate's own self-test — it counts only if its positive control and its mutation arm both pass.\n\nDo NOT run the baseline regenerator to 'fix' this: regeneration derives the anchor FROM the line number, so on a drifted baseline it computes a legitimate-looking anchor for the WRONG LINE and exits clean."}}
JSON
exit 0

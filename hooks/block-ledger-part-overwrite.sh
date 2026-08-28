#!/usr/bin/env bash
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":ledger-hygiene:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
. "$(dirname "$0")/lib/log-denial.sh" 2>/dev/null || true
set -u
IN="$(cat)"
CMD="$(printf '%s' "$IN" | python -c "import sys,json;print(json.load(sys.stdin).get('tool_input',{}).get('command',''))" 2>/dev/null)" || exit 0
[ -z "$CMD" ] && exit 0

printf '%s' "$CMD" | grep -q 'PART-REWRITE-ACK' && exit 0

printf '%s' "$CMD" | grep -qE '[-_][0-9]{2}\.md|[-_]pt[0-9]+\.md' || exit 0

TOKENS="$(printf '%s' "$CMD" | grep -oE '[A-Za-z0-9_./:\\-]*[-_]([0-9]{2}|pt[0-9]+)\.md' | sort -u)"
[ -z "$TOKENS" ] && exit 0

CLOBBER=0
CMD_NOFD="$(printf '%s' "$CMD" | sed -E 's/[0-9]*>&([0-9]+|-)//g')"
if printf '%s' "$CMD_NOFD" | grep -qE '(^|[^>=!<-])>[^>=]' ; then CLOBBER=1; fi
printf '%s' "$CMD" | grep -qE '(^|[;&| ])(mv|cp)[[:space:]]' && CLOBBER=1
printf '%s' "$CMD" | grep -qE '(^|[;&| ])tee[[:space:]]' && ! printf '%s' "$CMD" | grep -qE 'tee[[:space:]]+-a' && CLOBBER=1
[ "$CLOBBER" -eq 0 ] && exit 0

targets_part() {
  esc=$(printf '%s' "$1" | sed 's/[][\.^$*+?(){}|/\\]/\\&/g')
  printf '%s' "$CMD_NOFD" | grep -qE "(^|[^>=!<-])>&?[[:space:]]*[\"']?${esc}" && return 0
  printf '%s' "$CMD" | grep -qE "(^|[;&| ])(mv|cp)[[:space:]][^;&|]*${esc}[[:space:]]*(\$|[;&|])" && return 0
  if printf '%s' "$CMD" | grep -qE "(^|[;&| ])tee[[:space:]][^;&|]*${esc}"; then
    printf '%s' "$CMD" | grep -qE 'tee[[:space:]]+-a' || return 0
  fi
  return 1
}

CDDIRS="$(printf '%s' "$CMD" | grep -oE 'cd[[:space:]]+[A-Za-z0-9_./:\\-]+' | sed 's/^cd[[:space:]]*//')"

for t in $TOKENS; do
  case "$t" in
    *.claude*|*archive*|*-log-*) ;;
    *) continue ;;
  esac
  targets_part "$t" || continue
  HIT=""
  if [ -f "$t" ]; then HIT="$t"; fi
  if [ -z "$HIT" ]; then
    for d in $CDDIRS; do
      if [ -f "$d/$t" ]; then HIT="$d/$t"; break; fi
    done
  fi
  t="${HIT:-}"
  if [ -n "$t" ] && [ -f "$t" ]; then
    aal_log_denial "block-ledger-part-overwrite" "site-1" "deny" 2>/dev/null || true
    printf '{"decision":"block","reason":"LEDGER-PART OVERWRITE GUARD: the command contains an OVERWRITING write whose target is the existing part %s. A numbered ledger part is frozen history and is never rewritten. FIX: (1) ls <name>-*.md to see which numbers are taken; (2) write to the next free number; (3) append-only (>>) to the ACTIVE file is always allowed. If you genuinely must rewrite this frozen part, save a copy first and append the comment #PART-REWRITE-ACK to the command." , "systemMessage":"blocked: existing ledger part %s would be overwritten"}' "$t" "$t"
    exit 0
  fi
done
exit 0

#!/usr/bin/env bash
set -uo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":pipeline-roles:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
BL="$(aal_resolve_project_dir)/.claude/BACKLOG.md"
[ -f "$BL" ] || exit 0

issues=""

bad=$(grep -E '^### ' "$BL" | grep -vE '^### \[(QUEUED|IN-DEV|REVIEW|BLOCKED|USER-GATED)\] ' || true)
if [ -n "$bad" ]; then
  n=$(printf '%s\n' "$bad" | grep -c . || true)
  issues="${issues}[${n} title(s) not in ### [STATUS] format / carrying a legacy status badge] "
fi

sl=$(grep -cE '^- \*\*status:' "$BL" 2>/dev/null || true)
[ "${sl:-0}" -gt 0 ] && issues="${issues}[${sl} residual legacy status: dual-track line(s) — delete → move to log:] "

dn=$(grep -cE '^### \[DONE\]' "$BL" 2>/dev/null || true)
[ "${dn:-0}" -gt 0 ] && issues="${issues}[${dn} [DONE] card(s) lingering on the active board — move to archive] "

if [ -n "$issues" ]; then
  msg="⚠️ BACKLOG single-status format drift: ${issues}— convention: each card = ### [STATUS] name·P (STATUS in QUEUED/IN-DEV/REVIEW/BLOCKED/USER-GATED), status only in the header, the body keeps only log:, a DONE card moves to BACKLOG-archive.md."
  printf '{"systemMessage":"%s"}' "$(printf '%s' "$msg" | sed 's/\\/\\\\/g; s/"/\\"/g')"
fi
exit 0

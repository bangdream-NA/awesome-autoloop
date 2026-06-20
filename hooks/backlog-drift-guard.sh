#!/usr/bin/env bash
# backlog-drift-guard (Stop hook) — enforce a single-status BACKLOG.md format (warn-only backstop).
# Roots out a dual-status-field drift: an old format with a title status badge AND a card-end
# `status:` line, both manually maintained → they inevitably diverge. The single-status convention:
# each card = `### [STATUS] name · P`, status lives ONLY in the header, the body keeps only a log:,
# a DONE card moves to BACKLOG-archive.md. This is the Stop-tier backstop to the write-time deny
# gate (block-backlog-status-drift) — pure bash (no node), so it runs even on a node-less box.
set -uo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":pipeline-roles:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
BL="$(aal_resolve_project_dir)/.claude/BACKLOG.md"
[ -f "$BL" ] || exit 0

issues=""

# 1) Each card title must be `### [STATUS] name` (STATUS in the whitelist); no legacy emoji
#    badge / ✅ / MERGED / DONE.
bad=$(grep -E '^### ' "$BL" | grep -vE '^### \[(QUEUED|IN-DEV|REVIEW|BLOCKED|USER-GATED)\] ' || true)
if [ -n "$bad" ]; then
  n=$(printf '%s\n' "$bad" | grep -c . || true)
  issues="${issues}[${n} title(s) not in ### [STATUS] format / carrying a legacy status badge] "
fi

# 2) No residual legacy `status:` current-status body line (status lives only in the header; the
#    body keeps history under log:). Tolerated as a migration-debt warn (a board migrated from a
#    Chinese SOP might still carry the `状态:` line).
sl=$(grep -cE '^- \*\*状态[:：]' "$BL" 2>/dev/null || true)
[ "${sl:-0}" -gt 0 ] && issues="${issues}[${sl} residual legacy status: dual-track line(s) — delete → move to log:] "

# 3) The active board must not carry [DONE] (after merge + DoD the whole card moves to
#    BACKLOG-archive.md).
dn=$(grep -cE '^### \[DONE\]' "$BL" 2>/dev/null || true)
[ "${dn:-0}" -gt 0 ] && issues="${issues}[${dn} [DONE] card(s) lingering on the active board — move to archive] "

if [ -n "$issues" ]; then
  msg="⚠️ BACKLOG single-status format drift: ${issues}— convention: each card = ### [STATUS] name·P (STATUS in QUEUED/IN-DEV/REVIEW/BLOCKED/USER-GATED), status only in the header, the body keeps only log:, a DONE card moves to BACKLOG-archive.md."
  printf '{"systemMessage":"%s"}' "$(printf '%s' "$msg" | sed 's/\\/\\\\/g; s/"/\\"/g')"
fi
exit 0

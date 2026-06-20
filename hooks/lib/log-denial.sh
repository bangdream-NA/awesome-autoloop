#!/usr/bin/env bash
# log-denial.sh — shared best-effort denial-event recorder for awesome-autoloop deny gates.
#
# A deny hook sources this and calls `aal_log_denial <hook-name> <pattern-id> <short-reason>`
# on its deny branch (alongside its existing struggle-log write). One pipe-delimited line is
# appended to <project>/.claude/.gate-denials so the self-improve skill can mine recurring footguns.
#
# CONTRACT (AC-8 / AC-15):
#  - NODE-FREE: only [ -f ]/date/echo/mkdir/wc — sourceable by enforce-planner-first.sh which has no node.
#  - BEST-EFFORT: every write is `|| true`-guarded; a read-only FS / missing dir NEVER alters the caller's
#    verdict (the caller's deny JSON is already emitted before/around this call — see per-hook §A-2).
#  - SAME .claude/ AS struggle-log: reuses aal_resolve_project_dir, writes to <dir>/.claude IFF it exists,
#    else $HOME/.claude — mirroring the adopters' struggle-log resolution so the two never split.
#  - BOUNDED (AC-10): rotates .gate-denials -> .gate-denials.1 when it crosses 240KB, before the 256KB
#    Read ceiling. Keeps ONE rotation (.1); a third rotation overwrites .1 (denial history is mine-then-act,
#    not an audit trail — one rotation of tail history is plenty and bounds total disk to <480KB).
#
# Requires lib/activation.sh already sourced (for aal_resolve_project_dir). Callers source both.

AAL_GATE_DENIALS_CAP="${AAL_GATE_DENIALS_CAP:-245760}"   # 240 KiB, below the 256KB Read hard-error

# aal_log_denial <hook-name> <pattern-id> <short-reason>
aal_log_denial() {
  local hook="${1:-unknown}" pid="${2:-unknown}" reason="${3:-}"
  local dir claude_dir log line
  dir=$(aal_resolve_project_dir 2>/dev/null || echo "")
  if [ -n "$dir" ] && [ -d "$dir/.claude" ]; then
    claude_dir="$dir/.claude"
  else
    claude_dir="$HOME/.claude"
  fi
  [ -d "$claude_dir" ] || mkdir -p "$claude_dir" 2>/dev/null || return 0
  log="$claude_dir/.gate-denials"
  # Rotate BEFORE append when over cap (best-effort; failure leaves the file, never errors the gate).
  if [ -f "$log" ]; then
    local sz
    sz=$(wc -c < "$log" 2>/dev/null | tr -d ' ')
    case "$sz" in (*[!0-9]*|'') sz=0 ;; esac
    if [ "$sz" -gt "$AAL_GATE_DENIALS_CAP" ]; then
      mv -f "$log" "$log.1" 2>/dev/null || true
    fi
  fi
  # Sanitize delimiters/newlines out of the reason so each event is exactly one greppable line.
  reason=$(printf '%s' "$reason" | tr '\n|' '  ')
  line="$(date +%Y-%m-%dT%H:%M:%S%z) | $hook | $pid | $reason"
  printf '%s\n' "$line" >> "$log" 2>/dev/null || true
  return 0
}

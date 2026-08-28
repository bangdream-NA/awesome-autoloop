#!/usr/bin/env bash
#  - NODE-FREE: only [ -f ]/date/echo/mkdir/wc — sourceable by enforce-planner-first.sh which has no node.

AAL_GATE_DENIALS_CAP="${AAL_GATE_DENIALS_CAP:-245760}"

aal_log_denial() {
  local hook="${1:-unknown}" pid="${2:-unknown}" reason="${3:-}"
  local dir claude_dir log line
  dir=$(aal_resolve_project_dir 2>/dev/null || echo "")
  if [ -n "$dir" ] && [ -d "$dir/.claude" ]; then
    claude_dir="$dir/.claude"
  else
    claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  fi
  [ -d "$claude_dir" ] || mkdir -p "$claude_dir" 2>/dev/null || return 0
  log="$claude_dir/.gate-denials"
  if [ -f "$log" ]; then
    local sz
    sz=$(wc -c < "$log" 2>/dev/null | tr -d ' ')
    case "$sz" in (*[!0-9]*|'') sz=0 ;; esac
    if [ "$sz" -gt "$AAL_GATE_DENIALS_CAP" ]; then
      mv -f "$log" "$log.1" 2>/dev/null || true
    fi
  fi
  reason=$(printf '%s' "$reason" | tr '\n|' '  ')
  line="$(date +%Y-%m-%dT%H:%M:%S%z) | $hook | $pid | $reason"
  printf '%s\n' "$line" >> "$log" 2>/dev/null || true
  return 0
}

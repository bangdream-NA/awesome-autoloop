#!/usr/bin/env bash

set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":pipeline-roles:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0

STATE_DIR="${CLAUDE_PLUGIN_DATA:-${XDG_STATE_HOME:-$HOME/.local/state}}"
mkdir -p "$STATE_DIR" 2>/dev/null || true
LOG_FILE="$STATE_DIR/aal-tool-call-log"
INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | sed -n 's/.*"tool_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' 2>/dev/null || echo "unknown")
CALL_HASH=$(printf '%s' "$INPUT" | cksum 2>/dev/null | cut -d' ' -f1)
[ -z "$CALL_HASH" ] && CALL_HASH="$TOOL_NAME"
ENTRY="${TOOL_NAME}:${CALL_HASH}"

echo "$ENTRY" >> "$LOG_FILE" 2>/dev/null || true
tail -10 "$LOG_FILE" > "${LOG_FILE}.tmp" 2>/dev/null && mv "${LOG_FILE}.tmp" "$LOG_FILE" 2>/dev/null || true

COUNT=0
while IFS= read -r line; do
  if [ "$line" = "$ENTRY" ]; then
    COUNT=$((COUNT + 1))
  else
    COUNT=0
  fi
done < "$LOG_FILE" 2>/dev/null || true

if [ "$COUNT" -ge 3 ]; then
  echo "WARNING: Loop detected — identical $TOOL_NAME call made $COUNT times consecutively. Step back and try a different approach." >&2
  exit 2
fi

exit 0

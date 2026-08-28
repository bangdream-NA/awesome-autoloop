#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib/parse-json.sh"
INPUT=$(cat)

STOP_ACTIVE=$(json_get "$INPUT" stop_hook_active)
[ "$STOP_ACTIVE" = "true" ] && exit 0

# Scope: only projects that run this convention. The source this was ported from tested for the
# author's own checkout by absolute path; sanitising that literal left a path no adopter can have, so
# the hook could never fire anywhere. The activation guard is what every other hook here uses, and it
# is what that literal was always standing in for.
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0

WINDOW="${ANOMALY_GUARD_THROTTLE_SECS:-1800}"
SESSION_ID=$(json_get "$INPUT" session_id)
STATE_DIR="$(dirname "$0")/.state"
STATE_FILE="$STATE_DIR/anomaly-recording-check-${SESSION_ID:-global}.last"
NOW=$(date +%s)
if [ -f "$STATE_FILE" ]; then
  LAST=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
  case "$LAST" in (*[!0-9]*|'') LAST=0 ;; esac
  [ $((NOW - LAST)) -lt "$WINDOW" ] && exit 0
fi
mkdir -p "$STATE_DIR" 2>/dev/null || true
echo "$NOW" > "$STATE_FILE" 2>/dev/null || true
find "$STATE_DIR" -name 'anomaly-recording-check-*.last' -mtime +2 -delete 2>/dev/null || true

cat <<'EOF'
{"decision":"block","reason":"Anomaly check. Default SKIP. During any first-hand live observation this turn, did you see a broken/unreasonable live state you did NOT record on BACKLOG? An anomaly IS a finding, never an obstacle — register the bug card now. Otherwise stop, no commentary.","suppressOutput":true}
EOF
exit 0

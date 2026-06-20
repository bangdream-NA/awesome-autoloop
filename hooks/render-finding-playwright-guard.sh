#!/usr/bin/env bash
# render-finding-playwright-guard.sh — Stop check (consolidated via stop-dispatcher.sh): enforce
# "render / user-visible findings are INDEPENDENTLY verified on the LIVE artifact before being
# reported as confirmed or sent to a fix".
#
# An audit's finders/verifiers often use curl/grep (a real browser is a single-instance tool, it
# can't fan out across many agents) — so the lead must do the live pass. A render / duplication /
# count / element-presence claim about what the USER SEES is proven by a SCREENSHOT read visually
# (or live getComputedStyle / post-hydration DOM), NEVER curl/grep or a raw querySelectorAll count.
# A memorized rule the lead keeps skipping is DECORATIVE; this turn-end reminder makes it DETECTED.
# Default SKIP, throttled, loop-guarded — same pattern as oplog-turn-reminder.sh.
set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":dod-walk:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
source "$(dirname "$0")/lib/parse-json.sh"
aal_have_node || exit 0   # fail-OPEN: a turn-end reminder must not block on a node-less box
INPUT=$(cat)

# Loop guard: fire once per turn.
STOP_ACTIVE=$(json_get "$INPUT" stop_hook_active)
[ "$STOP_ACTIVE" = "true" ] && exit 0

# Throttle: fire at most once per WINDOW per session.
WINDOW="${RENDER_GUARD_THROTTLE_SECS:-1800}"
SESSION_ID=$(json_get "$INPUT" session_id)
STATE_DIR="${CLAUDE_PLUGIN_DATA:-${TMPDIR:-/tmp}}/aal-state"
mkdir -p "$STATE_DIR" 2>/dev/null || true
STATE_FILE="$STATE_DIR/render-playwright-guard-${SESSION_ID:-global}.last"
NOW=$(date +%s)
if [ -f "$STATE_FILE" ]; then
  LAST=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
  case "$LAST" in (*[!0-9]*|'') LAST=0 ;; esac
  [ $((NOW - LAST)) -lt "$WINDOW" ] && exit 0
fi
echo "$NOW" > "$STATE_FILE" 2>/dev/null || true
find "$STATE_DIR" -name 'render-playwright-guard-*.last' -mtime +2 -delete 2>/dev/null || true

cat <<'EOF'
{"decision":"block","reason":"Render-verification check (audit triage->report enforcement). Default SKIP. Did this turn relay/triage an audit finding as a CONFIRMED real bug, OR dispatch/approve a fix for a user-visible/render finding, WITHOUT INDEPENDENTLY verifying its premise on the LIVE artifact (for a web app a browser screenshot read VISUALLY / getComputedStyle / post-hydration DOM; for an api/data surface a curl of the live endpoint/shard) — relying only on the audit's curl/grep? A render / duplication / count / element-presence claim about what the USER SEES is proven by a SCREENSHOT, NEVER curl/grep or a raw querySelectorAll count (which over-counts hydration-transient + broad-selector + off-screen nodes). Also distinguish a DATA bug (curl the source) from a USER-VISIBLE RENDER bug (verify the rendered surface) — different severity + fix layer. If YES (a render/user-visible finding was treated as confirmed or sent to a fix without your own live pass): verify it yourself NOW before acting/merging, per your project's nature (web -> browser screenshot; api/data -> curl the endpoint/shard). If no render finding was handled this turn, or you already verified each: stop immediately with NO commentary.","systemMessage":"render->live verify check","suppressOutput":true}
EOF
exit 0

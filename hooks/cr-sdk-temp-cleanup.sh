#!/usr/bin/env bash
set -uo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":pipeline-roles:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
TEMP_DIR="${TEMP:-${TMPDIR:-${USERPROFILE:-$HOME}/AppData/Local/Temp}}"
THRESHOLD_SEC=$((24 * 3600))
NOW=$(date +%s)
FREED_BYTES=0
FREED_COUNT=0
shopt -s nullglob 2>/dev/null || true
for f in "$TEMP_DIR"/cr_sdk_*.tmp; do
  [ -e "$f" ] || continue
  # 🔴 Same GNU/BSD split as block-merge-on-board-drift.sh, failing in the OTHER direction: with
  # only `stat -c`, macOS takes the `|| echo "$NOW"` branch, AGE is 0, nothing is ever older than
  # the threshold, and this hook silently cleans nothing while reporting nothing. `%m`/`%z` are the
  # BSD spellings of `%Y`/`%s`.
  MTIME=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo "$NOW")
  AGE=$((NOW - MTIME))
  if [ "$AGE" -gt "$THRESHOLD_SEC" ]; then
    SIZE=$(stat -c %s "$f" 2>/dev/null || stat -f %z "$f" 2>/dev/null || echo 0)
    if rm -f "$f" 2>/dev/null; then
      FREED_BYTES=$((FREED_BYTES + SIZE))
      FREED_COUNT=$((FREED_COUNT + 1))
    fi
  fi
done
if [ "$FREED_COUNT" -gt 0 ]; then
  FREED_GB=$(awk "BEGIN{printf \"%.1f\", $FREED_BYTES/1073741824}")
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"cr_sdk temp cleanup: removed %s orphaned cr_sdk_*.tmp file(s), freed ~%sGB (mtime > 24h)."}}' "$FREED_COUNT" "$FREED_GB"
fi
exit 0

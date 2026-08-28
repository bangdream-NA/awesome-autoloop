#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib/parse-json.sh"
source "$(dirname "$0")/lib/log-denial.sh"

INPUT=$(cat)
COMMAND=$(json_get "$INPUT" command || echo "")
[ -z "$COMMAND" ] && exit 0
printf '%s' "$COMMAND" | grep -q 'gh pr merge' || exit 0

# Both spellings of an absolute path. Anchored to a drive letter alone, this gate resolved no
# directory at all on Linux or macOS and exited 0 in silence — indistinguishable from a clean board.
# `-E`, because `\|` is a GNU extension to BRE: BSD sed reads it as a literal pipe, the whole
# expression then matches NOTHING for every input, and the silence comes straight back on macOS.
DIR=$(printf '%s' "$COMMAND" | sed -nE 's#^cd ([A-Za-z]:/[^ ;&|"]*|/[^ ;&|"]*).*#\1#p')
# Git Bash spells a Windows drive as a one-letter first segment (`/c/proj`), which the ledger
# readers downstream do not understand. One character is a CONVENTION, not a guarantee — `/w/proj`
# is a legal POSIX repository — so the drive spelling is adopted only when it names a real
# directory. `tr`, not sed's `\U`, which is GNU-only and would print a literal `U` on BSD sed.
case "$DIR" in
  /[A-Za-z]/*)
    DRIVE=$(printf '%s' "$DIR" | cut -c2 | tr '[:lower:]' '[:upper:]')
    WINDIR="$DRIVE:${DIR#/?}"
    if [ -d "$WINDIR" ]; then DIR="$WINDIR"; fi
    ;;
esac
[ -z "$DIR" ] && exit 0
STATE="$DIR/.claude/.reconcile-state.json"
[ -f "$STATE" ] || exit 0

# 🔴 `stat -c` is GNU-only; BSD/macOS spells it `stat -f %m`. With only the GNU form the call
# fails, 2>/dev/null swallows the error, MT becomes 0, NOW-0 is ~1.8 billion, the staleness test
# below passes and this gate exits 0 IN SILENCE -- byte-identical to a clean board. A merge gate
# that fails open on a supported platform is the defect class this kit exists to remove. The
# chained form is the repo's own, from check-stale-agents.sh; `echo 0` is now reachable only when
# BOTH spellings fail, i.e. the state file vanished between the -f test above and this line.
NOW=$(date +%s); MT=$(stat -c %Y "$STATE" 2>/dev/null || stat -f %m "$STATE" 2>/dev/null || echo 0)
[ $((NOW - MT)) -gt 43200 ] && exit 0

grep -q '"dirty": *true' "$STATE" || exit 0

N=$(grep -o '"driftCount": *[0-9]*' "$STATE" | grep -o '[0-9]*' || echo '?')
aal_log_denial "bash-gh-pr-merge-preflight" "block-merge-on-board-drift" "board dirty ($N drift) — autoloop locked" || true
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: AUTOLOOP DRIFT LOCK (merge side). %s/.claude/BACKLOG.md has %s unresolved DRIFT item(s) against machine truth, so merging is locked. FIX: fix them one by one (a MERGED #N ack / the stage status), then run AAL_BACKLOG=%s/.claude/BACKLOG.md AAL_REPO=<owner/repo> node <hooks>/backlog-reconcile.mjs — a clean run unlocks it automatically."}}' "$DIR" "$N" "$DIR"
exit 0

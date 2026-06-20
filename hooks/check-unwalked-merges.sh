#!/usr/bin/env bash
# check-unwalked-merges.sh — Stop hook (turn-end HARD gate).
#
# Enforces the post-merge walk constraint MECHANICALLY: a soft additionalContext reminder
# (post-pr-merge-walk-reminder.sh) is easy to ignore. This gate BLOCKS turn-end if any merged
# PR lacks a walk artifact (a recorded live/final-artifact verification).
#
# Mechanism:
#   - post-pr-merge-walk-reminder.sh writes `.claude/walks/.pending-pr<N>` on merge.
#   - This hook, at every Stop, scans those sentinels:
#       * if any walk artifact (.claude/walks/*.md) mentions the PR# → auto-clear (walked, or marked N/A there)
#       * else → add to block list
#   - block list non-empty → decision:block with the PR list.
#
# To clear a non-UI / infra PR that needs no walk: write a line in any
# .claude/walks/*.md (or a NOTES file) like "PR #N: non-UI, walk N/A".
# Honors stop_hook_active (no re-block loop).

set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":dod-walk:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0

source "$(dirname "$0")/lib/parse-json.sh"

# A Stop HARD gate that fail-CLOSED on node-absent would BLOCK every turn-end on a node-less
# box — worse than skipping a discipline nudge. So node-guard = fail OPEN here (exit 0).
aal_have_node || exit 0

INPUT=$(cat 2>/dev/null || echo '{}')

# Don't re-fire if we're already inside a Stop-hook-triggered continuation.
STOP_ACTIVE=$(json_get "$INPUT" stop_hook_active)
[ -n "$STOP_ACTIVE" ] && exit 0

# Resolve the current autoloop project's walks dir (works from canonical or worktree).
WALKS_DIR="$(aal_resolve_project_dir)/.claude/walks"
[ -d "$WALKS_DIR" ] || exit 0

# Collect pending sentinels
shopt -s nullglob 2>/dev/null || true
PENDING=("$WALKS_DIR"/.pending-pr*)
[ ${#PENDING[@]} -eq 0 ] && exit 0

BLOCKED=""
for sentinel in "${PENDING[@]}"; do
  [ -e "$sentinel" ] || continue
  PR=$(basename "$sentinel" | sed -E 's/^\.pending-pr//')
  [ -z "$PR" ] && continue
  # Does any walk artifact mention this PR#? (grep #N as a word-ish token)
  if grep -rqE "#${PR}\b|PR[[:space:]]*${PR}\b|pr${PR}\b" "$WALKS_DIR"/*.md 2>/dev/null; then
    rm -f "$sentinel" 2>/dev/null || true   # walked (or N/A-noted) → clear
  else
    BLOCKED="${BLOCKED} #${PR}"
  fi
done

[ -z "$BLOCKED" ] && exit 0

REASON="POST-MERGE WALK REQUIRED before ending. These merged PRs have no walk artifact in ${WALKS_DIR}/:${BLOCKED}. Either (a) verify the live/final artifact per your project's nature (for a web app a real-browser Playwright walk or a curl of the deployed page; for a CLI run the built binary; for a library exercise the public API) and write/append a .claude/walks/*.md artifact mentioning each PR#, OR (b) for non-UI/infra PRs, add a line 'PR #N: non-UI, walk N/A — <reason>' to a walks .md. Re-stopping after that auto-clears the gate."

# Stop-hook block schema
printf '{"decision":"block","reason":"%s"}\n' "$REASON"
exit 0

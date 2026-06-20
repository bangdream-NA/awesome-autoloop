#!/usr/bin/env bash
# worktree-count-guard.sh — Stop hook. DETECTED guard against worktree pile-up.
# Backstop for the failure where the post-wave cleanup rule goes un-enforced and dozens of
# stale worktrees + branches accumulate. Silent unless over threshold.
#
# This only applies to a multi-worktree topology: set AAL_WORKTREE_ROOT (the slug your wave
# worktrees live under, e.g. the leaf dir name) in your settings.json env to enable it. If it
# is unset (single-tree users), the hook NO-OPS — you won't be nagged.
set -eu
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":ledger-hygiene:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
WT_SLUG="${AAL_WORKTREE_ROOT:-}"
[ -z "$WT_SLUG" ] && exit 0   # single-tree: nothing to guard
REPO="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || echo "")}"
[ -n "$REPO" ] && [ -d "$REPO/.git" ] || exit 0
CAP="${AAL_WORKTREE_CAP:-12}"
WT=$(git -C "$REPO" worktree list 2>/dev/null | grep -c "$WT_SLUG" || true)
WT=${WT:-0}
if [ "$WT" -gt "$CAP" ]; then
  msg="WORKTREE GUARD: ${WT} worktrees under \"${WT_SLUG}\" (cap ${CAP}). Prune the non-active ones: git worktree remove --force. (Branch pruning is per-merge via enforce-delete-branch-on-merge; for a backlog, delete branches whose name is in \`gh pr list --state merged --json headRefName\`.)"
  printf '{"systemMessage":"%s"}' "$(printf '%s' "$msg" | sed 's/\\/\\\\/g; s/"/\\"/g')"
fi
exit 0

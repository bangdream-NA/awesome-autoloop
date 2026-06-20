#!/usr/bin/env bash
# block-pr-merge-stale-base.sh — PreToolUse/Bash.
# Refuses `gh pr merge <N>` when the PR's base is stale (branched before subsequent merges to
# origin/<base>): a squash-merge now could silently revert the in-between merged work. The
# primary protection is rebase-before-push; this is the cheap advisory backstop.
# Rule: any PR open against origin/main must rebase onto current main before merge.
#
# stdin = harness-provided JSON: {tool_name, tool_input, ...}
# Only fires when tool_name === Bash AND command contains `gh pr merge`.

set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":merge-gates:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0

source "$(dirname "$0")/lib/parse-json.sh"

if ! aal_have_node; then
  cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: awesome-autoloop requires node on PATH to evaluate this gate, and node was not found. Install node >=18, or disable the plugin / remove this gate group from AAL_GATES. (Fail-closed: a security gate that can't evaluate must not silently allow.)"}}
JSON
  exit 0
fi

PAYLOAD=$(cat)

# Extract tool name + command (hook-envelope fields → lib json_get)
TOOL=$(json_get "$PAYLOAD" tool_name)
if [ "$TOOL" != "Bash" ]; then
  exit 0
fi

CMD=$(json_get "$PAYLOAD" command)

# Match `gh pr merge` (with or without --squash/--rebase/--merge/--delete-branch/etc.)
# Allow `gh pr merge --help` and similar non-action invocations through.
if ! printf '%s' "$CMD" | grep -qE 'gh[[:space:]]+pr[[:space:]]+merge'; then
  exit 0
fi
if printf '%s' "$CMD" | grep -qE 'gh[[:space:]]+pr[[:space:]]+merge[[:space:]]+--help'; then
  exit 0
fi

# Extract PR number — multiple shapes accepted:
#   gh pr merge 270
#   gh pr merge 270 --squash --delete-branch
#   gh pr merge --squash 270
# (no PR number = "use current branch's PR" — we skip the check in that
#  case rather than guess wrong)
PR_NUM=$(printf '%s' "$CMD" | grep -oE 'gh[[:space:]]+pr[[:space:]]+merge[[:space:]]+(--[a-z-]+([[:space:]]+--[a-z-]+)*[[:space:]]+)?[0-9]+' | grep -oE '[0-9]+$' || true)
if [ -z "$PR_NUM" ]; then
  exit 0
fi

# LAST `cd <dir>` in the command (effective cwd); was first-cd-anywhere (`head -1`), which
# mis-targeted `cd a && cd b && gh pr merge` → resolved to `a` (§0.4 E3). pwd stays the fail-OPEN
# fallback — this gate is an advisory backstop, not a hard deny, so an unresolved repo must NOT block.
REPO_DIR=$(aal_extract_cd_target "$CMD")
if [ -z "$REPO_DIR" ] || [ ! -d "$REPO_DIR" ]; then
  REPO_DIR=$(pwd)
fi
if [ ! -d "$REPO_DIR/.git" ] && ! git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  # Not a git repo we can introspect — fail open (don't block).
  exit 0
fi

# Fetch latest origin/main + PR head ref. Quietly.
git -C "$REPO_DIR" fetch origin main 2>/dev/null || exit 0

# Resolve gh. Fail OPEN (allow) if gh is not installed — the merge-gate stack
# needs gh elsewhere, so a missing gh surfaces there, not as a stale-base deny.
GH=$(command -v gh 2>/dev/null || echo "")
[ -n "$GH" ] || exit 0

# Get PR's head SHA + base ref name.
PR_JSON=$("$GH" pr view "$PR_NUM" --repo "$(git -C "$REPO_DIR" config --get remote.origin.url | sed -E 's#.*github\.com[:/]([^/]+)/([^/.]+)(\.git)?#\1/\2#')" --json headRefOid,baseRefName 2>/dev/null || echo "")
if [ -z "$PR_JSON" ]; then
  exit 0
fi
# These parse arbitrary gh PR JSON (NOT the hook envelope), so json_get's
# envelope contract doesn't apply — keep the inline node extraction.
HEAD_SHA=$(printf '%s' "$PR_JSON" | node -e "let s=''; process.stdin.on('data',c=>s+=c); process.stdin.on('end',()=>{try{process.stdout.write(JSON.parse(s).headRefOid||'')}catch{}});" 2>/dev/null || echo "")
BASE_REF=$(printf '%s' "$PR_JSON" | node -e "let s=''; process.stdin.on('data',c=>s+=c); process.stdin.on('end',()=>{try{process.stdout.write(JSON.parse(s).baseRefName||'main')}catch{}});" 2>/dev/null || echo "main")

if [ -z "$HEAD_SHA" ]; then
  exit 0
fi

# Compare diff-against-base file count vs diff-against-live-main file count.
# If live-main diff has MORE files than base diff, those extra files came from
# in-between merged commits — stale-base risk.
MAIN_SHA=$(git -C "$REPO_DIR" rev-parse "origin/$BASE_REF" 2>/dev/null)
if [ -z "$MAIN_SHA" ]; then
  exit 0
fi

# If PR head IS already a descendant of current main, no stale-base.
if git -C "$REPO_DIR" merge-base --is-ancestor "$MAIN_SHA" "$HEAD_SHA" 2>/dev/null; then
  exit 0
fi

# Stale-base detected. Count in-between merged commits + their files.
BETWEEN_COMMITS=$(git -C "$REPO_DIR" log --oneline "$HEAD_SHA..origin/$BASE_REF" 2>/dev/null | head -5)
BETWEEN_COUNT=$(printf '%s' "$BETWEEN_COMMITS" | grep -c . || echo 0)

if [ "$BETWEEN_COUNT" = "0" ]; then
  exit 0
fi

cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "BLOCKED: PR #$PR_NUM has stale base (branched before $BETWEEN_COUNT subsequent merge(s) to origin/$BASE_REF). Squash-merging now risks silently reverting in-between merged work.\n\nIn-between merged commits (PR head .. origin/$BASE_REF):\n$BETWEEN_COMMITS\n\nFIX before merging:\n  cd <pr-worktree> && git fetch origin && git rebase origin/$BASE_REF && git push --force-with-lease origin HEAD\n\nThen re-dispatch reviewer round 2 to verify the post-rebase diff is exactly the PR's intended scope.\n\nTo bypass intentionally (NOT RECOMMENDED): inspect 'git diff origin/$BASE_REF..PR-HEAD --stat' manually first to confirm no scope spill."
  }
}
EOF
exit 0

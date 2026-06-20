#!/usr/bin/env bash
# EXAMPLE — not mounted; copy into your own ~/.claude/hooks/ + wire it in your settings.json.
#
# A prod-topology gate: allow automated production-mutating commands ONLY from the canonical
# checkout (on main, clean, HEAD aligned with origin/main) — never from a feature worktree.
# This is the SHAPE of a project-specific gate; replace the placeholders with your own:
#   <your-canonical-checkout>  the one dir prod ops may run from (e.g. /path/to/main-checkout)
#   <your-host>                your production SSH host alias
#   <your-repo>                your origin "owner/repo" slug
#   <your-deploy-script>       your deploy entry point (e.g. scripts/deploy.sh)
#
# PreToolUse runs before the shell executes a leading `cd`, so this hook parses the intended
# leading `cd <dir> &&` and evaluates THAT directory instead of the hook's own cwd.
set -euo pipefail
source "$(dirname "$0")/lib/parse-json.sh"

INPUT=$(cat)
COMMAND=$(json_get "$INPUT" command)

CANONICAL_DIR="<your-canonical-checkout>"   # e.g. /path/to/your/main-checkout
HOST="<your-host>"                          # e.g. your prod SSH alias
REPO="<your-repo>"                          # e.g. owner/repo

IS_LOCAL_DEPLOY=0
IS_SSH_HOST=0

echo "$COMMAND" | grep -qE '<your-deploy-script>|wrangler[[:space:]]+deploy' && IS_LOCAL_DEPLOY=1
echo "$COMMAND" | grep -qE "\bssh[[:space:]]+([^[:space:]]+@)?${HOST}\b" && IS_SSH_HOST=1

# Not a production-mutation command: pass through.
[ "$IS_LOCAL_DEPLOY" -eq 0 ] && [ "$IS_SSH_HOST" -eq 0 ] && exit 0

deny() {
  local reason; reason=$(printf '%s' "$1" | tr '\n' ' ' | sed 's/\\/\\\\/g; s/"/\\"/g')
  cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED prod mutation: $reason. Precondition: run from the canonical checkout on main, clean, HEAD=origin/main — or start the command with cd <your-canonical-checkout> && git pull --ff-only before the deploy."}}
EOF
  exit 0
}

# Resolve the intended cwd from a leading `cd <dir> &&`.
CHECK_DIR="$(pwd)"
LEADING_CD_DIR=$(echo "$COMMAND" | sed -nE 's/^[[:space:]]*cd[[:space:]]+"?([^"&;]+)"?[[:space:]]*(&&|;|$).*/\1/p' | head -1 | tr -d '"' | sed 's/[[:space:]]*$//')
[ -n "$LEADING_CD_DIR" ] && CHECK_DIR="$LEADING_CD_DIR"

GIT_DIR=$(git -C "$CHECK_DIR" rev-parse --git-dir 2>/dev/null || echo "")
[ -z "$GIT_DIR" ] && deny "command cwd '$CHECK_DIR' is not a git repo"

REPO_URL=$(git -C "$CHECK_DIR" remote get-url origin 2>/dev/null || echo "")
echo "$REPO_URL" | grep -qF "$REPO" || deny "origin remote ($REPO_URL) is not $REPO"

REASONS=""
case "$GIT_DIR" in */.git/worktrees/*) REASONS="${REASONS}cwd is a worktree; " ;; esac
[ "$CHECK_DIR" = "$CANONICAL_DIR" ] || REASONS="${REASONS}cwd is '$CHECK_DIR' (must be $CANONICAL_DIR); "
BRANCH=$(git -C "$CHECK_DIR" branch --show-current 2>/dev/null || echo "")
[ "$BRANCH" = "main" ] || [ "$BRANCH" = "master" ] || REASONS="${REASONS}branch is '$BRANCH' (must be main); "
DIRTY=$(git -C "$CHECK_DIR" status --short 2>/dev/null | head -5 || echo "")
[ -n "$DIRTY" ] && REASONS="${REASONS}working tree dirty; "

[ -n "$REASONS" ] && deny "$REASONS"
exit 0

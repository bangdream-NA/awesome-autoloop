#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib/parse-json.sh"

INPUT=$(cat)
COMMAND=$(json_get "$INPUT" command)

CANONICAL_DIR="<your-canonical-checkout>"
HOST="<your-host>"
REPO="<your-repo>"
DEPLOY_SCRIPT="<your-deploy-script>"
PUBLISH_ENDPOINT="<your-publish-endpoint>"

IS_LOCAL_DEPLOY=0
IS_SSH_HOST=0
IS_REPUBLISH=0

if echo "$COMMAND" | grep -qF "$DEPLOY_SCRIPT"; then
  SEG=$(printf '%s\n' "$COMMAND" | tr '&|;' '\n' | grep -m1 -F "$DEPLOY_SCRIPT" || true)
  W1=$(printf '%s' "$SEG" | awk '{print $1}')
  W2=$(printf '%s' "$SEG" | awk '{print $2}')
  W3=$(printf '%s' "$SEG" | awk '{print $3}')
  case "$W1" in
    *"$DEPLOY_SCRIPT") IS_LOCAL_DEPLOY=1 ;;
    bash|sh|sudo)
      case "$W2" in
        -n) : ;;
        *"$DEPLOY_SCRIPT") IS_LOCAL_DEPLOY=1 ;;
        bash|sh) case "$W3" in *"$DEPLOY_SCRIPT") IS_LOCAL_DEPLOY=1 ;; esac ;;
      esac ;;
  esac
fi
echo "$COMMAND" | grep -qE 'wrangler[[:space:]]+deploy' && IS_LOCAL_DEPLOY=1
echo "$COMMAND" | grep -qE "\bssh[[:space:]]+([^[:space:]]+@)?${HOST}\b" && IS_SSH_HOST=1
echo "$COMMAND" | grep -qF "$PUBLISH_ENDPOINT" && IS_REPUBLISH=1

[ "$IS_LOCAL_DEPLOY" -eq 0 ] && [ "$IS_SSH_HOST" -eq 0 ] && [ "$IS_REPUBLISH" -eq 0 ] && exit 0

json_escape() { printf '%s' "$1" | tr '\n' ' ' | sed 's/\\/\\\\/g; s/"/\\"/g'; }

deny() {
  local reason; reason=$(json_escape "$1")
  cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED prod mutation: $reason. Precondition: run from the canonical $CANONICAL_DIR checkout on main, status clean, HEAD=origin/main — or start the command with cd $CANONICAL_DIR && git pull --ff-only before the deploy. ALREADY WROTE THE cd AND STILL DENIED? cd must be the FIRST token: a leading set -o pipefail, an export or a comment hides it from this gate. If a pipe forces you to front-load set -o pipefail, drop the pipe instead — redirect to a file and filter in the next command."}}
EOF
  exit 0
}

canonicalize_path() {
  local p="$1"
  p="${p%/}"; p="${p%\\}"; p="${p//\\//}"
  printf '%s' "$p"
}

CANON_LC=$(printf '%s' "$CANONICAL_DIR" | tr '[:upper:]' '[:lower:]')
CANON_DRIVE=$(printf '%s' "$CANON_LC" | cut -c1)
CANON_TAIL=$(printf '%s' "$CANON_LC" | cut -c3-)

is_canonical_dir() {
  local p; p=$(canonicalize_path "$1" | tr '[:upper:]' '[:lower:]')
  case "$p" in
    "$CANON_LC"|"/${CANON_DRIVE}${CANON_TAIL}"|"/mnt/${CANON_DRIVE}${CANON_TAIL}") return 0 ;;
  esac
  return 1
}

extract_leading_cd_dir() {
  local command="$1"
  local sep='(&&|;|$)'
  if [[ "$command" =~ ^[[:space:]]*cd[[:space:]]+\"([^\"]+)\"[[:space:]]*${sep} ]]; then
    printf '%s' "${BASH_REMATCH[1]}"; return 0
  fi
  if [[ "$command" =~ ^[[:space:]]*cd[[:space:]]+([^[:space:];&]+)[[:space:]]*${sep} ]]; then
    printf '%s' "${BASH_REMATCH[1]}"; return 0
  fi
  printf ''
}

CHECK_DIR="$(pwd)"
LEADING_CD_DIR="$(extract_leading_cd_dir "$COMMAND")"
[ -n "$LEADING_CD_DIR" ] && CHECK_DIR="$LEADING_CD_DIR"

HAS_SYNC_BEFORE_MUTATION=0
if echo "$COMMAND" | grep -qE "git[[:space:]]+pull[^&|;]*--ff-only.*($DEPLOY_SCRIPT|wrangler[[:space:]]+deploy|ssh[[:space:]]+([^[:space:]]+@)?${HOST}|$PUBLISH_ENDPOINT)"; then
  HAS_SYNC_BEFORE_MUTATION=1
fi

if [ "$IS_SSH_HOST" -eq 1 ] && [ "$IS_LOCAL_DEPLOY" -eq 0 ] && [ "$IS_REPUBLISH" -eq 0 ]; then
  REMOTE_CMD=$(echo "$COMMAND" | sed -E "s/.*ssh[[:space:]]+([^[:space:]]+@)?${HOST}[[:space:]]*(--[[:space:]]+)?//" | tr -d "'\"")
  WRITE_PATTERN='(^|[[:space:]])(bash|sh|rm|cp|mv|chmod|chown|sudo|kill|killall|apt|apt-get|npm|pnpm|yarn|dpkg)([[:space:]]|$)|systemctl[[:space:]]+(restart|reload|stop|start|enable|disable|mask|unmask)|curl[[:space:]]+[^|]*-X[[:space:]]+(POST|PUT|DELETE|PATCH)|[[:space:]]>[[:space:]]|\|[[:space:]]*tee'
  HAS_WRITE=0
  echo "$REMOTE_CMD" | grep -qE "$WRITE_PATTERN" && HAS_WRITE=1
  [ "$HAS_WRITE" -eq 0 ] && exit 0
fi

GIT_DIR=$(git -C "$CHECK_DIR" rev-parse --git-dir 2>/dev/null || echo "")
[ -z "$GIT_DIR" ] && deny "command cwd '$CHECK_DIR' is not a git repo"

REPO_URL=$(git -C "$CHECK_DIR" remote get-url origin 2>/dev/null || echo "")
echo "$REPO_URL" | grep -qF "$REPO" || deny "origin remote ($REPO_URL) is not $REPO"

REASONS=""
case "$GIT_DIR" in */.git/worktrees/*) REASONS="${REASONS}cwd is a worktree; " ;; esac
is_canonical_dir "$CHECK_DIR" || REASONS="${REASONS}command cwd is '$CHECK_DIR' (must be $CANONICAL_DIR); "
BRANCH=$(git -C "$CHECK_DIR" branch --show-current 2>/dev/null || echo "")
[ "$BRANCH" = "main" ] || [ "$BRANCH" = "master" ] || REASONS="${REASONS}branch is '$BRANCH' (must be main); "
DIRTY=$(git -C "$CHECK_DIR" status --short --untracked-files=no 2>/dev/null | head -5 || echo "")
if [ -n "$DIRTY" ]; then
  DIRTY_PREVIEW=$(echo "$DIRTY" | tr '\n' '|' | sed 's/|$//')
  REASONS="${REASONS}working tree dirty ($DIRTY_PREVIEW); "
fi

if [ "$BRANCH" = "main" ] || [ "$BRANCH" = "master" ]; then
  REMOTE_SHA=$(git -C "$CHECK_DIR" rev-parse "origin/$BRANCH" 2>/dev/null || echo "")
  LOCAL_SHA=$(git -C "$CHECK_DIR" rev-parse HEAD 2>/dev/null || echo "")
  if echo "$REMOTE_SHA" | grep -qE '^[0-9a-f]{40}$' && [ "$LOCAL_SHA" != "$REMOTE_SHA" ] && [ "$HAS_SYNC_BEFORE_MUTATION" -eq 0 ]; then
    REASONS="${REASONS}HEAD (${LOCAL_SHA:0:7}) != origin/$BRANCH (${REMOTE_SHA:0:7}); "
  fi
fi

[ -n "$REASONS" ] && deny "$REASONS"
exit 0

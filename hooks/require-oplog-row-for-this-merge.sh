#!/usr/bin/env bash
set -uo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":merge-gates:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
source "$(dirname "$0")/lib/parse-json.sh"
if ! aal_have_node; then
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"HARD GATE (op-log): node is not available to parse this merge command. Run the merge where node is available."}}'
  exit 0
fi
PAYLOAD=$(cat)
CMD=$(json_get "$PAYLOAD" command)
printf '%s' "$CMD" | grep -qE '\bgh[[:space:]]+pr[[:space:]]+merge\b' || exit 0
if [ -n "${AAL_OPLOG_DIR:-}" ]; then
  OPLOG_DIR="$AAL_OPLOG_DIR"
else
  PROJ_DIR=$(aal_extract_cd_target "$CMD")
  if [ -z "$PROJ_DIR" ] || [ ! -d "$PROJ_DIR" ]; then
    cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"HARD GATE (op-log, fail-closed): cannot resolve WHICH project this merge belongs to — no `cd <project-dir>` found in the command. Run it as `cd <project-dir> && gh pr merge <N> ...` so the gate checks THAT project's op-log. The gate never guesses or defaults to another project's ledger (R-13 cross-wire fix)."}}
EOF
    exit 0
  fi
  OPLOG_DIR="$PROJ_DIR/.claude"
fi
ls "$OPLOG_DIR"/autoloop-log-*.md >/dev/null 2>&1 || exit 0
NUM=$(printf '%s' "$CMD" | grep -oE '\bgh[[:space:]]+pr[[:space:]]+merge[[:space:]]+[0-9]+' | grep -oE '[0-9]+$' | head -1 || true)
if [ -z "$NUM" ]; then
  cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"HARD GATE (op-log): write the PR number explicitly — 'gh pr merge <N> --squash --delete-branch'. A bare 'gh pr merge' (implicit current-branch) bypasses the op-log row check; this gate stays gh-free by reading the PR# from the command itself, so the number is required. Re-run with the explicit PR number."}}
EOF
  exit 0
fi
if grep -lE "#${NUM}([^0-9]|\$)" "$OPLOG_DIR"/autoloop-log-*.md >/dev/null 2>&1; then exit 0; fi
cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"HARD GATE (op-log): PR #${NUM} has NO ledger row in any ${OPLOG_DIR}/autoloop-log-*.md. Add a feature·problem·proof row citing #${NUM} to the project's op-log (any session's autoloop-log-*.md) FIRST, then re-run the merge. Self-contained (PR# read from the merge command, no gh call) so it CANNOT fail-open — every wave MUST be logged BEFORE it lands."}}
EOF
exit 0

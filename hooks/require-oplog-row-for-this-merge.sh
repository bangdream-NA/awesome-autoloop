#!/usr/bin/env bash
# require-oplog-row-for-this-merge.sh — PreToolUse(Bash). HARD GATE (deny, fails CLOSED).
# Before `gh pr merge <N>`, require the op-log (autoloop-log-*.md, latest) to ALREADY contain a row
# for #<N>. Self-contained: extracts <N> from the merge command itself — NO `gh` call → CANNOT
# fail-open on a gh hiccup the way a `gh pr list`-based gate can (empty result → allow). Also gates
# THE merge being run (not the prior one), so the LAST wave is forced too.
#
# NO-OP UNLESS the op-log convention exists: a project with no autoloop-log-*.md file no-ops
# (see the L-guard below) — the gate is harmless until you adopt the op-log ledger.
set -uo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":merge-gates:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
source "$(dirname "$0")/lib/parse-json.sh"
# Fail CLOSED on node-absent: a deny gate must not silently allow an unlogged merge.
if ! aal_have_node; then
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"HARD GATE (op-log): node is not available to parse this merge command. Run the merge where node is available."}}'
  exit 0
fi
PAYLOAD=$(cat)
CMD=$(json_get "$PAYLOAD" command)
# only gate an actual `gh pr merge`
printf '%s' "$CMD" | grep -qE '\bgh[[:space:]]+pr[[:space:]]+merge\b' || exit 0
# Resolve WHICH project this merge belongs to via the shared R-13 helper aal_extract_cd_target —
# the LAST `cd <dir>` ANYWHERE in the command (= the shell's effective cwd at merge time, so a
# compound `git -C X … && cd X && gh pr merge` resolves correctly). This is the SAME resolver the
# 8 R-13-unified merge gates use (require-backlog-reconciled / require-pr-green / …). Class-A
# fail-CLOSED: if no cd resolves we DENY — NEVER fall back to a env/git guess that could cross-wire
# the merge to another project's ledger (the exact failure R-13 closed). AAL_OPLOG_DIR overrides the
# dir entirely (fixtures/portability) and short-circuits the cd-resolution.
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
# no-op unless the op-log convention exists here (ANY autoloop-log-*.md present — own or legacy).
# Under the per-session model the #<N> row may sit in ANY session's ledger, so we grep-ALL below
# rather than resolving a single mtime-latest file (which would miss a row in a non-latest ledger).
ls "$OPLOG_DIR"/autoloop-log-*.md >/dev/null 2>&1 || exit 0
# first integer right after `gh pr merge` = the PR number
NUM=$(printf '%s' "$CMD" | grep -oE '\bgh[[:space:]]+pr[[:space:]]+merge[[:space:]]+[0-9]+' | grep -oE '[0-9]+$' | head -1 || true)
# In an op-log project, FORBID an implicit `gh pr merge` (no explicit PR#). Adding a `gh pr view`
# fallback to recover the number would re-introduce the fail-open gh dependency this self-contained
# gate exists to avoid — so require the number instead. DENY.
if [ -z "$NUM" ]; then
  cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"HARD GATE (op-log): write the PR number explicitly — 'gh pr merge <N> --squash --delete-branch'. A bare 'gh pr merge' (implicit current-branch) bypasses the op-log row check; this gate stays gh-free by reading the PR# from the command itself, so the number is required. Re-run with the explicit PR number."}}
EOF
  exit 0
fi
# row present in ANY session/legacy ledger? (grep-ALL across every autoloop-log-*.md, not a single
# mtime-latest file — the owning session may have written the row to its own per-session ledger.)
if grep -lE "#${NUM}([^0-9]|\$)" "$OPLOG_DIR"/autoloop-log-*.md >/dev/null 2>&1; then exit 0; fi
cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"HARD GATE (op-log): PR #${NUM} has NO ledger row in any ${OPLOG_DIR}/autoloop-log-*.md. Add a feature·problem·proof row citing #${NUM} to the project's op-log (any session's autoloop-log-*.md) FIRST, then re-run the merge. Self-contained (PR# read from the merge command, no gh call) so it CANNOT fail-open — every wave MUST be logged BEFORE it lands."}}
EOF
exit 0

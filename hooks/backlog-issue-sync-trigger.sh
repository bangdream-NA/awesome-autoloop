#!/usr/bin/env bash
set -euo pipefail

case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":pipeline-roles:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
INPUT="$(cat)"
FILE="$(printf '%s' "$INPUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const p=JSON.parse(s);process.stdout.write((p.tool_input&&(p.tool_input.file_path||""))||"")}catch{}})' 2>/dev/null || true)"

case "$FILE" in
  *BACKLOG.md|*BACKLOG-archive.md|*BACKLOG.md\"|*BACKLOG-archive.md\") ;;
  *) exit 0 ;;
esac

. "$(dirname "$0")/lib/is-autoloop-lead.sh" 2>/dev/null || true
_REPO=$(aal_resolve_repo "$INPUT" "$FILE" 2>/dev/null || echo "")
[ -z "$_REPO" ] && exit 0
_GH=$(git -C "$_REPO" remote get-url origin 2>/dev/null | sed -E 's#(git@github\.com:|https://github\.com/)##; s#\.git$##' || echo "")
[ -z "$_GH" ] && exit 0

AAL_BACKLOG="$_REPO/.claude/BACKLOG.md" AAL_REPO="$_GH" \
  node "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/backlog-issue-sync.mjs" --apply \
  >> "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.backlog-issue-sync.log" 2>&1 || true
exit 0

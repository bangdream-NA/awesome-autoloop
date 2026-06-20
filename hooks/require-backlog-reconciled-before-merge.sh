#!/usr/bin/env bash
# PreToolUse(Bash) HARD GATE — block `gh pr merge` when the active BACKLOG board still has a card
# for an ALREADY-MERGED PR (merged but never archived). Enforces merge-then-archive: the prior
# batch MUST be reconciled before a new merge opens. fail-CLOSED (gh failure / unresolvable repo →
# deny). Pairs with the Stop-hook backstop (backlog-drift-guard.sh) which covers the tail (the
# just-merged card itself, which this PreToolUse gate cannot see on its own merge).
#
# WHY: a soft post-merge-cleanup reminder is DECORATIVE — it gets ignored across merges and merged
# cards pile up stale on the board. ENFORCED>DETECTED>DECORATIVE → this is the fail-closed gate.
#
# Cross-ref (in require-backlog-reconciled-before-merge.cjs) uses each active card's PRIMARY alias
# (first token of `- aliases:`) vs recent merged-PR branch-slugs (headRefName minus feat/), so
# absorbed history aliases (a card listing an absorbed sibling slug) do NOT false-fire.
set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":merge-gates:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
source "$(dirname "$0")/lib/parse-json.sh"
INPUT=$(cat)
if ! aal_have_node; then
  # Merge gate: node-absent must NOT silently allow an unreconciled merge → fail-CLOSED.
  cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: awesome-autoloop requires node on PATH to evaluate this merge-reconcile gate, and node was not found. Install node >=18, or disable the plugin / remove the merge-gates group from AAL_GATES. (Fail-closed: a gate that can't evaluate must not silently allow an unreconciled merge.)"}}
JSON
  exit 0
fi

TOOL=$(json_get "$INPUT" tool_name)
[ "$TOOL" = "Bash" ] || exit 0
CMD=$(json_get "$INPUT" command)
printf '%s' "$CMD" | grep -qE '\bgh[[:space:]]+pr[[:space:]]+merge\b' || exit 0

# Resolve the project board + repo. Prefer a leading `cd <dir> &&` prefix on the merge command
# (the standing worktree merge convention); else fall back to the session project (env/git) via the
# activation lib — never a hardcoded project. Board = <proj>/.claude/BACKLOG.md, repo = THAT
# project's origin remote. A resolvable board whose repo can't be resolved → fail CLOSED, never
# cross-wire (Q3).
# Resolve the project from the LAST `cd <dir>` in the merge command (its effective cwd).
# NO env/default fallback on the BOARD path — an unresolvable cd must DENY (fail-closed), never
# cross-wire to another project's board (the 2026-06-11 incident: a compound `git -C X … && cd X &&
# gh pr merge` with the old leading-^ anchor matched no cd → fell through to the wrong board). §0.4.
PROJ_DIR=$(aal_extract_cd_target "$CMD")
if [ -z "$PROJ_DIR" ] || [ ! -d "$PROJ_DIR" ]; then
  cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED merge (fail-closed): cannot resolve WHICH project this merge belongs to — no `cd <project-dir>` found in the command. Run it as `cd <project-dir> && gh pr merge <N> ...` so the gate reconciles THAT project's BACKLOG. The gate never guesses or defaults to another project's board."}}
JSON
  exit 0
fi
BACKLOG="$PROJ_DIR/.claude/BACKLOG.md"
[ -f "$BACKLOG" ] || exit 0   # no backlog convention here → not our gate
REPO=$(git -C "$PROJ_DIR" remote get-url origin 2>/dev/null | sed -E 's#\.git$##; s#^(https://[^/]+/|git@[^:]+:)##' || true)
if [ -z "$REPO" ]; then
  cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED merge (fail-closed): the project has a .claude/BACKLOG.md but its git origin remote could not be resolved, so the merged-PR cross-ref cannot run. Fix the origin remote (or correct the cd prefix) and re-run."}}
JSON
  exit 0
fi

# Distinguish gh FAILURE (deny, fail-closed) from gh SUCCESS with zero merged PRs (a brand-new
# repo's FIRST merge — legitimate): sentinel __NONE__ on success-but-empty.
if MERGED_RAW=$(gh pr list --repo "$REPO" --state merged --limit 15 --json headRefName --jq '.[].headRefName' 2>/dev/null); then
  MERGED_SLUGS=$(printf '%s' "$MERGED_RAW" | sed 's#^feat/##' | grep -v '^$' || true)
  [ -z "$MERGED_SLUGS" ] && MERGED_SLUGS="__NONE__"
else
  MERGED_SLUGS=""
fi

node "$(dirname "$0")/require-backlog-reconciled-before-merge.cjs" "$BACKLOG" "$MERGED_SLUGS"
exit 0

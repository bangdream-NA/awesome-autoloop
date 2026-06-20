#!/usr/bin/env bash
# activation.sh — shared autoloop-project activation guard for awesome-autoloop hooks.
#
# A gate must ONLY enforce inside a project that opted into the framework. The plugin mounts
# its hooks GLOBALLY (every repo Claude works in once enabled), so without this guard every
# deny gate fires in unrelated repos. This resolves the project dir and returns truthy iff the
# project carries an autoloop marker.
#
# NODE-FREE BY DESIGN: only [ -f ] / grep, no node. It MUST run BEFORE each hook's node-guard,
# else a non-autoloop repo on a node-less box hits the fail-closed node-deny before the no-op.
#
# Resolution order (same as require-review-before-ship.sh):
#   1. CLAUDE_PROJECT_DIR env (set by Claude Code at session start)
#   2. main repo from `git rev-parse --git-common-dir` (works from worktrees)
#   3. git toplevel (only correct when not in a worktree)
#   4. cwd as last resort
# An OPTIONAL first arg is a leading-`cd <dir>` target a PreToolUse/Bash hook already parsed
# out of the command (so `cd <project> && git push` from HOME resolves the project). Stop /
# Agent / UserPromptSubmit hooks have no command — they call it with no arg.

# TRUST BOUNDARY (R-13): CLAUDE_PROJECT_DIR is ranked above git-common-dir because the harness
# injects it ACCURATELY at session start for a single-project session (the common case). It is the
# WRONG answer only when pinned/poisoned (a stale settings.json hardcode) or in a multi-project home
# session. The MERGE/SHIP BOARD gates therefore DO NOT use this resolver for the merge target — they
# extract the `cd <dir>` from the command (aal_extract_cd_target) and FAIL CLOSED if none resolves,
# so a poisoned env can never cross-wire a merge to the wrong project's board. See docs/OPERATING.md.

# aal_resolve_project_dir [optional_cd_dir] -> echoes the resolved project dir
aal_resolve_project_dir() {
  local cd_hint="${1:-}"
  if [ -n "$cd_hint" ] && [ -d "$cd_hint" ]; then echo "$cd_hint"; return; fi
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then echo "$CLAUDE_PROJECT_DIR"; return; fi
  local common_dir
  common_dir=$(git rev-parse --git-common-dir 2>/dev/null || echo "")
  if [ -n "$common_dir" ]; then
    case "$common_dir" in
      /*|[A-Za-z]:*) ;;                         # already absolute
      *) common_dir="$(pwd)/$common_dir" ;;     # --git-common-dir may be relative (".git")
    esac
    case "$common_dir" in
      */.git) echo "${common_dir%/.git}" ;;
      *) dirname "$common_dir" ;;
    esac
    return
  fi
  git rev-parse --show-toplevel 2>/dev/null || pwd
}

# aal_extract_cd_target <command-string> -> echoes the LAST `cd <dir>` target ANYWHERE in the
# command (= the shell's effective cwd at run time), or EMPTY if none. Handles compound forms
# (`git -C X && cd Y && …`), multiple cd (last wins), `;`/`&&` separators, and quoted paths with
# spaces. Does NOT resolve `(subshell)` cd or a bare relative `cd -` to a project — those return
# EMPTY / a non-dir, so the caller's `[ -d ]` guard or fail-closed deny handles them (§0.4/§0.5).
# Verbatim-aligned with HOME's board-gate extraction (require-backlog-reconciled/require-oplog-row),
# RUN against the full R-13 edge-case matrix before locking. The caller decides policy on the
# result (Class-A board gates fail-closed on empty/non-dir; Class-B cd-into gates fall to their
# env/git fallback; Class-C stays fail-open).
aal_extract_cd_target() {
  printf '%s' "${1:-}" \
    | grep -oE '(^|&&|;)[[:space:]]*cd[[:space:]]+"?[^"&;|]+' \
    | tail -1 \
    | sed -E 's/^(&&|;)*[[:space:]]*cd[[:space:]]+"?//; s/[[:space:]]*$//' \
    || true
}

# aal_is_autoloop_project [optional_cd_dir] -> rc 0 if the resolved project is autoloop-managed
aal_is_autoloop_project() {
  local dir
  dir=$(aal_resolve_project_dir "${1:-}")
  [ -n "$dir" ] || return 1
  [ -f "$dir/.claude/.autoloop" ]        && return 0   # explicit installer/user anchor
  [ -f "$dir/.claude/BACKLOG.md" ]       && return 0   # pipeline board
  [ -f "$dir/.claude/code-reviews.md" ]  && return 0   # review ledger
  # CLAUDE.md managed block (cheap fixed-string grep; no regex)
  [ -f "$dir/.claude/CLAUDE.md" ] && grep -qF 'BEGIN awesome-autoloop' "$dir/.claude/CLAUDE.md" && return 0
  return 1
}

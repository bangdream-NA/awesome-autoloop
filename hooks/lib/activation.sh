#!/usr/bin/env bash
# NODE-FREE BY DESIGN: only [ -f ] / grep, no node. It MUST run BEFORE each hook's node-guard,
#   1. CLAUDE_PROJECT_DIR env (set by Claude Code at session start)

# TRUST BOUNDARY (R-13): CLAUDE_PROJECT_DIR is ranked above git-common-dir because the harness

aal_resolve_project_dir() {
  local cd_hint="${1:-}"
  if [ -n "$cd_hint" ] && [ -d "$cd_hint" ]; then echo "$cd_hint"; return; fi
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then echo "$CLAUDE_PROJECT_DIR"; return; fi
  local common_dir
  common_dir=$(git rev-parse --git-common-dir 2>/dev/null || echo "")
  if [ -n "$common_dir" ]; then
    case "$common_dir" in
      /*|[A-Za-z]:*) ;;
      *) common_dir="$(pwd)/$common_dir" ;;
    esac
    case "$common_dir" in
      */.git) echo "${common_dir%/.git}" ;;
      *) dirname "$common_dir" ;;
    esac
    return
  fi
  git rev-parse --show-toplevel 2>/dev/null || pwd
}

aal_extract_cd_target() {
  printf '%s' "${1:-}" \
    | grep -oE '(^|&&|;)[[:space:]]*cd[[:space:]]+"?[^"&;|]+' \
    | tail -1 \
    | sed -E 's/^(&&|;)*[[:space:]]*cd[[:space:]]+"?//; s/[[:space:]]*$//' \
    || true
}

aal_is_autoloop_project() {
  local dir
  dir=$(aal_resolve_project_dir "${1:-}")
  [ -n "$dir" ] || return 1
  [ -f "$dir/.claude/.autoloop" ]        && return 0
  [ -f "$dir/.claude/BACKLOG.md" ]       && return 0
  [ -f "$dir/.claude/code-reviews.md" ]  && return 0
  [ -f "$dir/.claude/CLAUDE.md" ] && grep -qF 'BEGIN awesome-autoloop' "$dir/.claude/CLAUDE.md" && return 0
  return 1
}

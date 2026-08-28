#!/usr/bin/env bash
git_config_poison() {
  local root="${1:-}" cfg line n
  [ -n "$root" ] || return 0
  cfg="$root/.git/config"
  [ -f "$cfg" ] || return 0

  line=$(grep -n '^[[:space:]]*worktree[[:space:]]*=' "$cfg" 2>/dev/null | head -1)
  [ -n "$line" ] || return 0
  n=${line%%:*}
  local val="${line#*=}"
  val="$(printf '%s' "$val" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  local why="this path does not exist on this filesystem"
  case "$val" in
    /mnt/*) why="a WSL mount path — resolves only inside WSL; Windows-native git dies on it" ;;
    *)
      if [ -d "$val" ]; then
        local rv rr
        rv="$(cd "$val" 2>/dev/null && pwd -P)"
        rr="$(cd "$root" 2>/dev/null && pwd -P)"
        if [ -n "$rv" ] && [ "$rv" = "$rr" ]; then
          return 0
        fi
        why="this directory EXISTS but is NOT this checkout — git here silently operates on a different tree"
      fi
      ;;
  esac

  printf '%s\n' \
    "🔴 GIT CONFIG POISONED — every git command in $root fails at CONFIG LOAD, before it reads a single ref." \
    "" \
    "    $cfg:$n" \
    "        worktree = $val        ← $why" \
    "" \
    "  Symptom you will see instead of anything useful:" \
    "        fatal: Invalid path '<prefix>': No such file or directory        rc=128" \
    "  …on EVERY git command here, including \`git config\` itself — so the usual" \
    "  \`git config --unset core.worktree\` repair is unavailable. Edit the file directly." \
    "" \
    "  CAUSE (measured 2026-08-09): a git command run from WSL inside a worktree wrote a" \
    "  WSL mount path (/mnt/...) into the MAIN repo's config. A normal checkout has NO" \
    "  core.worktree at all." \
    "" \
    "  FIX: back the file up, delete that ONE line, then verify all three:" \
    "        git -C $root rev-parse --short HEAD ; git -C $root status --porcelain ; git -C $root worktree list" \
    "" \
    "  PREVENTION: inside WSL do READ-ONLY git only. Never \`git -C <worktree> config …\`," \
    "  never \`git worktree add/repair\` from WSL against a Windows checkout."
  return 1
}

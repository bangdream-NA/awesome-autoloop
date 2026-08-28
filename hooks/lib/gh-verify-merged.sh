#!/usr/bin/env bash

resolve_cd_dir() {
  printf '%s' "$1" | grep -oE '(^|&&|;)[[:space:]]*cd[[:space:]]+"?[^"&;|]+' | tail -1 \
    | sed -E 's/^(&&|;)*[[:space:]]*cd[[:space:]]+"?//; s/[[:space:]]*$//' | tr -d '"'
}

gh_pr_state_json() {
  local pr="$1" dir="$2"
  [ -n "$dir" ] && [ -d "$dir" ] || { printf ''; return 0; }
  ( cd "$dir" 2>/dev/null && gh pr view "$pr" --json state,mergedAt 2>/dev/null ) || true
}

gh_pr_is_merged() {
  printf '%s' "$1" | node -e '
    let s=""; process.stdin.on("data",d=>s+=d);
    process.stdin.on("end",()=>{
      try {
        const j = JSON.parse(s);
        process.exit((j.state === "MERGED" && !!j.mergedAt) ? 0 : 1);
      } catch(_) { process.exit(1); }
    });
  ' 2>/dev/null
}

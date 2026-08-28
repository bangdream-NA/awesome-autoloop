
aal__lib_dir() { (cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd); }
aal__resolver() { printf '%s/is-autoloop-lead.mjs' "$(aal__lib_dir)"; }

aal_session_project() {
  printf '%s' "$1" | node "$(aal__resolver)" --session-project 2>/dev/null || printf '%s' ""
}

aal_resolve_repo() {
  printf '%s' "$1" | node "$(aal__resolver)" --resolve-repo "${2:-}" 2>/dev/null || printf '%s' ""
}

aal_repo_roots() {
  printf '%s' "$1" | node "$(aal__resolver)" --repo-roots "${2:-}" 2>/dev/null || printf '%s' ""
}

aal_worktree_parent() {
  node "$(aal__resolver)" --worktree-parent "${1:-}" 2>/dev/null || printf '%s' ""
}

aal_known_projects() {
  node "$(aal__resolver)" --known-projects 2>/dev/null || printf '%s' ""
}

aal_is_autoloop_lead() {
  local repo
  repo=$(aal_session_project "$1")
  [ -n "$repo" ]
}

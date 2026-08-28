#!/usr/bin/env bash
is_merge_invocation() {
  local cmd="$1" stripped
  stripped=$(printf '%s' "$cmd" | sed "s/'[^']*'//g" | sed 's/"[^"]*"//g')
  grep -qE '\bgh[[:space:]]+pr[[:space:]]+merge\b' <<<"$stripped"
}

# shellcheck disable=SC2034  # consumed by the files that source this library
GIT_GLOBAL_OPTS='([[:space:]]+(-C[[:space:]]+[^[:space:]]+|-c[[:space:]]+[^[:space:]]+|--git-dir=[^[:space:]]+|--work-tree=[^[:space:]]+))*'

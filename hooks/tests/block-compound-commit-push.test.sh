#!/usr/bin/env bash
# block-compound-commit-push — `git add && git commit && git push` is one Bash call, so when the
# push half is denied the WHOLE call fails and the commit silently never happened. The gate denies
# the compound shape and asks for two separate calls.
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/block-compound-commit-push.sh

# --- portable activation context ---------------------------------------------------------------
AAL_PROJ=/tmp/aal-fx-block-compound-commit-push
rm -rf "$AAL_PROJ"; mkdir -p "$AAL_PROJ/.claude"; : > "$AAL_PROJ/.claude/.autoloop"
export CLAUDE_PROJECT_DIR="$AAL_PROJ"
trap 'rm -rf "$AAL_PROJ"' EXIT
# -----------------------------------------------------------------------------------------------

p() { printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1"; }

# --- DENY: all three halves present — a write verb, a gated verb, and a separator ----------------
assert_deny "add && commit && push"   "$(p "git add -A && git commit -m wip && git push")" 'whole-command-deny'
assert_deny "commit ; push"           "$(p "git commit -m wip; git push origin main")"     'whole-command-deny'
assert_deny "add && gh pr merge"      "$(p "git add . && gh pr merge 12 --squash")"         'whole-command-deny'
assert_deny "a pipe is a separator too" "$(p "git commit -m wip | tee out.log && git push")" 'whole-command-deny'

# --- ALLOW: each half on its own is exactly what the gate is asking for --------------------------
assert_allow "commit alone"           "$(p "git commit -m wip")"
assert_allow "push alone"             "$(p "git push -u origin feat/r-widget")"
assert_allow "gh pr merge alone"      "$(p "git status && gh pr merge 12 --squash")"
assert_allow "add && commit, no push" "$(p "git add -A && git commit -m wip")"
assert_allow "unrelated compound"     "$(p "git fetch origin && git status")"

# 🔴 ASSERTED AS A DENY, not as a hole. A grep whose PATTERN happens to contain both verbs is
# denied, because the predicate reads the command text and cannot see that these bytes are data.
# That is not an oversight in the port: the gate's own denial text names the way out ("Doc/op-log
# rows mentioning these phrases: write via the Edit/Write tool, which bypass Bash gates"), so the
# behaviour is designed and the fixture pins it rather than papering over it.
assert_deny "the verbs quoted inside a grep pattern" \
  "$(p "grep -rn 'git commit && git push' docs/")" 'whole-command-deny'

summary

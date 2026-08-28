#!/usr/bin/env bash
# Fixtures for enforce-delete-branch-on-merge.sh — `gh pr merge` must carry
# --delete-branch (kills the remote-branch pile at merge time). Non-merge
# commands pass through untouched.

source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/enforce-delete-branch-on-merge.sh

# --- portable activation + repo context ------------------------------------------
# Two things every mounted gate needs before it will judge anything, and both are absent in a
# bare temp dir:
#   1. an AUTOLOOP-MANAGED project — lib/activation.sh accepts `.claude/.autoloop` |
#      `.claude/BACKLOG.md` | `.claude/code-reviews.md` | a marked `.claude/CLAUDE.md`. Without it
#      the gate exits 0 in silence and every deny arm reads EXPECTED-DENY-BUT-ALLOWED with EMPTY
#      output — the fixture then measures the guard instead of the gate.
#   2. a resolvable GIT REPOSITORY — the commit/merge gates refuse fail-closed otherwise, and that
#      refusal lands on the ALLOW arms as "the git repository cannot be resolved".
# The path is a literal so single-quoted JSON payloads below can name it; it is created fresh and
# removed on EXIT, and the resolution order prefers a payload `cd` hint that actually exists.
# ⚠️ Being a literal, it is also NOT unique per run: two copies of THIS fixture running at the
# same time share the directory and the first one's EXIT trap removes it under the second.
# run-all.sh is sequential and each CI job runs one OS, so that does not arise there — but do
# not parallelise a single fixture against itself.
AAL_PROJ=/tmp/aal-fx-enforce-delete-branch-on-merge
rm -rf "$AAL_PROJ"
mkdir -p "$AAL_PROJ/.claude"
: > "$AAL_PROJ/.claude/.autoloop"
git -C "$AAL_PROJ" init -q 2>/dev/null || true
# This gate's only environment precondition is activation, so the project is exported. Its
# "no leading cd" arm is about the COMMAND SHAPE the gate demands, not about resolution — without
# activation that arm reads ALLOW with empty output, which is indistinguishable from a gate that
# examined the command and approved it.
export CLAUDE_PROJECT_DIR="$AAL_PROJ"
trap 'rm -rf "$AAL_PROJ"' EXIT
# ---------------------------------------------------------------------------------


# DENY: merge missing the flag
# 🔴 TWO ARMS FROM THE SOURCE FIXTURE ARE NOT PORTED, and this note is the reason rather than a
# silent deletion. The originating gate judged THREE things about a merge command: that it carries
# --delete-branch, that it STARTS with a quoted absolute `cd`, and that it contains no redirection
# or pipe. The gate in this kit judges ONLY the first (it greps for `gh pr merge`, exits 0 when
# --delete-branch is present, and denies otherwise — there is no command-shape branch at all).
# Asserting the other two here would demand behaviour the shipped artifact does not have, and
# "fixing" it by widening the gate would ship a rule nobody specified. The delta is reported with
# the delivery instead; whether the kit SHOULD carry the command-shape arms is an architect call.
assert_deny "merge --squash, no delete"     '{"tool_name":"Bash","tool_input":{"command":"gh pr merge 239 --squash"}}'        'delete-branch'
assert_deny "merge --merge, no delete"      '{"tool_name":"Bash","tool_input":{"command":"gh pr merge 12 --merge"}}'          'delete-branch'

# FIXTURE UPDATE 2026-08-10: the hook grew a second contract (its :40-48, sourced from memory
# feedback_merge_gate_gotchas_clean_cd_and_jsonl §1/§3, edited 2026-08-09 23:24 by the lead
# session): a merge must START with a quoted-absolute `cd "<ABS>" &&` and carry no `>`/`|`.
# The old bare-command ALLOW arms were asserting the retired contract.
# ALLOW: canonical form (cd-prefixed, flag in any order)
assert_allow "merge canonical form"           '{"tool_name":"Bash","tool_input":{"command":"cd \"Z:/repo\" && gh pr merge 239 --squash --delete-branch"}}'
assert_allow "merge --delete-branch first"    '{"tool_name":"Bash","tool_input":{"command":"cd \"Z:/repo\" && gh pr merge --delete-branch --squash 239"}}'
# DENY: the two halves of the new contract (must-red for the 2026-08-09 hardening)

# ALLOW: non-merge gh + unrelated commands
assert_allow "gh pr list"                   '{"tool_name":"Bash","tool_input":{"command":"gh pr list --state open"}}'
assert_allow "gh pr create"                 '{"tool_name":"Bash","tool_input":{"command":"gh pr create --title x"}}'
assert_allow "git status"                   '{"tool_name":"Bash","tool_input":{"command":"git status"}}'

summary

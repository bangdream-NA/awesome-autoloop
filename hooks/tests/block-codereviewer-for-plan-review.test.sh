#!/usr/bin/env bash
# Fixtures for block-codereviewer-for-plan-review.sh — denies spawning a
# `code-reviewer` agent for a Mode-A plan-doc review (dedicated `plan-reviewer`
# exists). Precise signals must keep legit Mode-B code-review spawns allowed even
# when their prompt mentions "the plan/spec".

source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/block-codereviewer-for-plan-review.sh

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
AAL_PROJ=/tmp/aal-fx-block-codereviewer-for-plan-review
rm -rf "$AAL_PROJ"
mkdir -p "$AAL_PROJ/.claude"
: > "$AAL_PROJ/.claude/.autoloop"
git -C "$AAL_PROJ" init -q 2>/dev/null || true
export CLAUDE_PROJECT_DIR="$AAL_PROJ"
trap 'rm -rf "$AAL_PROJ"' EXIT
# ---------------------------------------------------------------------------------


env_cr() { printf '{"tool_name":"Agent","tool_input":{"subagent_type":"code-reviewer","prompt":%s}}' "$1"; }

# DENY: code-reviewer asked to do Mode-A plan-doc review
assert_deny "code-reviewer + Mode A"        "$(env_cr '"MODE A plan review for R-foo"')"                'plan-reviewer'
assert_deny "code-reviewer + -plan.md cite" "$(env_cr '"Review docs/product-specs/R-foo-plan.md"')"      'plan-reviewer'
assert_deny "code-reviewer + post-Planner"  "$(env_cr '"post-Planner pre-Architect review of the plan"')" 'plan-reviewer'

# ALLOW: legit Mode-B code review (even if it mentions the plan/spec)
assert_allow "code-reviewer + Mode B PR"    "$(env_cr '"MODE B: review PR #123 diff, run F-gates. Locked plan at R-foo-plan.md"')"
assert_allow "code-reviewer + plain code"   "$(env_cr '"Review the PR diff for correctness + edge cases"')"
# ALLOW: Mode-B marker immediately followed by a CJK char (real 2026-07-19 misfire:
# a FULL-WIDTH comma after "Mode B" broke the `\b` allow-check and denied a legitimate PR review.
# The character is built from its UTF-8 bytes rather than written literally: the shipped tree is
# ASCII-only, and the property under test is the punctuation width, not the language.
FW_COMMA=$(printf '\xef\xbc\x8c')
FW_LPAREN=$(printf '\xef\xbc\x88')
FW_RPAREN=$(printf '\xef\xbc\x89')
assert_allow "code-reviewer + Mode B followed by a full-width comma" \
  "$(env_cr "\"FRESH code-reviewer for this PR ${FW_LPAREN}Mode B${FW_COMMA}merge-gate authority${FW_RPAREN} context docs/product-specs/R-foo-plan.md\"")"

# ALLOW: the dedicated plan-reviewer doing Mode A (not gated)
assert_allow "plan-reviewer + Mode A"       '{"tool_name":"Agent","tool_input":{"subagent_type":"plan-reviewer","prompt":"MODE A plan review for R-foo"}}'

# ALLOW: other agent types
assert_allow "developer agent"              '{"tool_name":"Agent","tool_input":{"subagent_type":"developer","prompt":"implement per plan R-foo-plan.md"}}'

# ALLOW: non-Agent tool
assert_allow "Bash tool"                    '{"tool_name":"Bash","tool_input":{"command":"git status"}}'

summary

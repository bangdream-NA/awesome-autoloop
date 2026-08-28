#!/usr/bin/env bash
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/validate-agent-type.sh

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
AAL_PROJ=/tmp/aal-fx-validate-agent-type
rm -rf "$AAL_PROJ"
mkdir -p "$AAL_PROJ/.claude"
: > "$AAL_PROJ/.claude/.autoloop"
git -C "$AAL_PROJ" init -q 2>/dev/null || true
export CLAUDE_PROJECT_DIR="$AAL_PROJ"
trap 'rm -rf "$AAL_PROJ"' EXIT
# ---------------------------------------------------------------------------------


# Pipeline agents — allowed
for ROLE in planner plan-reviewer architect developer code-reviewer uiux-designer; do
  assert_allow "pipeline: $ROLE" \
    "{\"team_name\":\"foo\",\"subagent_type\":\"$ROLE\"}"
done

# Ad-hoc research — allowed
assert_allow "Explore (relaxed)" \
  '{"team_name":"foo","subagent_type":"Explore"}'

assert_allow "general-purpose (relaxed)" \
  '{"team_name":"foo","subagent_type":"general-purpose"}'

# Disallowed types
assert_deny  "claude (catch-all not allowed in team)" \
  '{"team_name":"foo","subagent_type":"claude"}' \
  "not in allowed list"

assert_deny  "statusline-setup (off-protocol)" \
  '{"team_name":"foo","subagent_type":"statusline-setup"}' \
  "not in allowed list"

# No team context — gate skipped (block-bare-agent owns this case)
assert_allow "no team_name — gate skipped" \
  '{"subagent_type":"claude"}'

summary

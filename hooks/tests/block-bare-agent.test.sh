#!/usr/bin/env bash
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/block-bare-agent.sh

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
AAL_PROJ=/tmp/aal-fx-block-bare-agent
rm -rf "$AAL_PROJ"
mkdir -p "$AAL_PROJ/.claude"
: > "$AAL_PROJ/.claude/.autoloop"
git -C "$AAL_PROJ" init -q 2>/dev/null || true
export CLAUDE_PROJECT_DIR="$AAL_PROJ"
trap 'rm -rf "$AAL_PROJ"' EXIT
# ---------------------------------------------------------------------------------


# Point the hook's deny-branch auto-logger at a temp project WITHOUT a struggle-log.md
# so fixture runs never append "Auto-blocked" rows to the real ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/struggle-log.md.
# 🔴 The scratch project lives OUTSIDE the repository. The source fixture put it at
# `$(dirname "$0")/.tmp-bareagent-$$`, i.e. inside hooks/tests/ — a `git add -A` after a fixture
# that was killed mid-run commits it, and no .gitignore rule covers that name.
# 🔴 It also carries `.claude/.autoloop`: this gate, like every mounted gate, exits 0 in silence
# unless the resolved project is autoloop-managed. Pointing CLAUDE_PROJECT_DIR at a plain temp dir
# deactivates the gate, and an inert gate reads through assert_deny as ALLOWED — six arms below
# went green-for-nothing that way.
TMPD="$(mktemp -d)"
mkdir -p "$TMPD/.claude"
: > "$TMPD/.claude/.autoloop"
trap 'rm -rf "$TMPD" "$AAL_PROJ"' EXIT
export CLAUDE_PROJECT_DIR="$TMPD"

# FIXTURE UPDATE 2026-08-09 (the user approved red-test repair): the expected substring was the OLD
# English wording `must carry a team_name`. `block-bare-agent.sh:34` now denies with
# The denial text was rewritten once without changing the verdict or the branch, and the
# copy. Both arms were reporting DENY-WRONG-REASON, i.e. the gate fired correctly and only the
# fixture's expectation went stale with it. The substring below is taken verbatim from the
# unique to this branch, so the arm keeps discriminating between the missing-field denial and the
# file's other deny branches (missing `name`, bad `subagent_type`, `run_in_background:true`).
# The payloads below are wrapped as {"tool_name":"Agent","tool_input":{...}} because that is the
# envelope this kit's gate reads. The source fixture passed a bare field bag; against this gate that
# produces EMPTY output on every arm — which `assert_deny` reports as ALLOWED, indistinguishable
# from a gate that looked at the dispatch and approved it.
# 🔴 THREE ARMS FROM THE SOURCE FIXTURE ARE NOT PORTED. The originating gate also judged the
#   `model` parameter (a pipeline role must not override the tier pinned in its frontmatter) and
#   the CONTENT of a reviewer brief (a hand-written verdict-ledger template). The gate in this kit
#   judges neither: it reads `subagent_type`, `name`, `team_name` and `run_in_background`, and has
#   no `model` or ledger-template branch at all. Asserting them here would demand behaviour the
#   shipped artifact does not have; widening the gate to match would ship a rule nobody specified.
#   Reported with the delivery instead — whether the kit SHOULD carry them is an architect call.
assert_deny  "no team_name" \
  '{"tool_name":"Agent","tool_input":{"subagent_type":"developer","description":"foo"}}' \
  "must go through a team"

assert_deny  "empty team_name string" \
  '{"tool_name":"Agent","tool_input":{"team_name":"","subagent_type":"developer"}}' \
  "must go through a team"

# 2026-07-11 contract (CC 2.1.207): run_in_background REMOVED from Agent schema —
# roster-teammate identity = non-empty `name`. Key ABSENT = new-version normal → ALLOW;
# explicit false (legacy call shape) → ALLOW; explicit true → still DENY; no name → DENY.
assert_allow "team_name + name, run_in_background omitted (2.1.207 normal)" \
  '{"tool_name":"Agent","tool_input":{"team_name":"my-team","subagent_type":"developer","name":"dev-x","description":"x","prompt":"y"}}'

assert_allow "legacy shape: team_name + name + bg:false still valid" \
  '{"tool_name":"Agent","tool_input":{"team_name":"port-2-resume-2","subagent_type":"developer","name":"dev-port2","run_in_background":false}}'

assert_allow "valid dispatch with other fields" \
  '{"tool_name":"Agent","tool_input":{"team_name":"my-team","subagent_type":"code-reviewer","name":"codereview-x","run_in_background":false,"description":"x","prompt":"y"}}'

assert_deny "pipeline role missing name" \
  '{"tool_name":"Agent","tool_input":{"team_name":"my-team","subagent_type":"developer"}}' \
  "must be a REAL roster teammate"

assert_deny "pipeline role, explicit run_in_background:true" \
  '{"tool_name":"Agent","tool_input":{"team_name":"my-team","subagent_type":"architect","name":"arch-x","run_in_background":true}}' \
  "must be a REAL roster teammate"

# incidental-text case (gate discipline duty c): the trigger phrase appearing as DATA
# inside the prompt must not flip the decision — name present → ALLOW.
assert_allow "incidental run_in_background text in prompt data" \
  '{"tool_name":"Agent","tool_input":{"team_name":"my-team","subagent_type":"planner","name":"planner-x","prompt":"docs mention run_in_background: true in old specs"}}'

# read-only research types are exempt from the roster requirements
assert_allow "Explore exempt (no name/bg needed)" \
  '{"tool_name":"Agent","tool_input":{"team_name":"my-team","subagent_type":"Explore","prompt":"find usages"}}'

# 2026-07-15 contract (the user LOCK): pipeline dispatches must OMIT the model param —
# it overrides the frontmatter pin and the alias enum resolves to stale versions.


# incidental-text ALLOW (§8 duty c): the word "model" inside the PROMPT string
# must not trip the structured top-level-field check.
assert_allow "incidental model text in prompt data" \
  '{"tool_name":"Agent","tool_input":{"team_name":"my-team","subagent_type":"developer","name":"dev-x","prompt":"read the data model docs; model: opus is mentioned in an old spec"}}'

# Explore/general-purpose stay exempt — model param allowed there (no frontmatter pin).
assert_allow "Explore with model param stays exempt" \
  '{"tool_name":"Agent","tool_input":{"team_name":"my-team","subagent_type":"Explore","model":"haiku","prompt":"broad search"}}'

# A reviewer dispatch brief must NOT hand-write
# a jsonl verdict-row template with the wrong field name. Canonical schema uses "plan" (plan-reviewer
# agent def line 123); a "wave"-keyed template → the jsonl-first architect gate (lib/plan-verdict.mjs
# reads r.plan) can't see the verdict → architect dispatch silently denied. Catch it AT SPAWN.

assert_allow "reviewer brief with correct plan-keyed template" \
  '{"tool_name":"Agent","tool_input":{"team_name":"t","subagent_type":"plan-reviewer","name":"pr-x","prompt":"append {\"plan\":\"R-foo\",\"verdict\":\"APPROVED\",\"mode\":\"A\"} to the ledger"}}'

# incidental-text ALLOW (§8 duty c): prose "wave" / a wave slug has no quote+colon → must not trip.
assert_allow "incidental prose wave mention (no json colon)" \
  '{"tool_name":"Agent","tool_input":{"team_name":"t","subagent_type":"plan-reviewer","name":"pr-x","prompt":"review the wave R-foo plan; record verdict per your agent definition"}}'

# reviewer-scoped: a non-reviewer role with a wave-colon in prompt DATA stays exempt (non-reviewers
# do not write verdict rows) — proves the check does not over-deny.
assert_allow "non-reviewer architect with wave-colon text exempt" \
  '{"tool_name":"Agent","tool_input":{"team_name":"t","subagent_type":"architect","name":"arch-x","prompt":"spec note: {\"wave\":\"foo\"} appears in a doc"}}'

summary

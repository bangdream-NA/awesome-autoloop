#!/usr/bin/env bash
# Fixtures for the coauthor check — blocks `git commit` whose message contains a
# Co-Authored-By line (case-insensitive). Non-commit commands and coauthor-free
# commits pass through. 2026-07-08: block-coauthor-commit.sh was consolidated into
# bash-commit-push-preflight.sh (hook-speed USER LOCK) — same stdin contract.

source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/bash-commit-push-preflight.sh

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
AAL_PROJ=/tmp/aal-fx-block-coauthor-commit
rm -rf "$AAL_PROJ"
mkdir -p "$AAL_PROJ/.claude"
: > "$AAL_PROJ/.claude/.autoloop"
git -C "$AAL_PROJ" init -q 2>/dev/null || true
export CLAUDE_PROJECT_DIR="$AAL_PROJ"
trap 'rm -rf "$AAL_PROJ"' EXIT
# ---------------------------------------------------------------------------------


# --- DENY: git commit carrying a Co-Authored-By line ---
assert_deny "commit w/ Co-Authored-By" \
  '{"command":"cd /tmp/aal-fx-block-coauthor-commit && git commit -m \"feat: x\\n\\nCo-Authored-By: Claude <bot@example.com>\""}' \
  'Co-Authored-By'

assert_deny "commit w/ lowercase co-authored-by" \
  '{"command":"cd /tmp/aal-fx-block-coauthor-commit && git commit -m \"fix: y\\n\\nco-authored-by: bot <b@x>\""}' \
  'Co-Authored-By'

# --- ALLOW: clean commit (no coauthor trailer) ---
assert_allow "clean conventional commit" \
  '{"command":"cd /tmp/aal-fx-block-coauthor-commit && git commit -m \"feat: clean change\""}'

# --- ALLOW: non-commit commands pass through, even if the string appears ---
assert_allow "non-commit echo containing the string" \
  '{"command":"echo Co-Authored-By: someone"}'

assert_allow "git status" \
  '{"command":"cd /tmp/aal-fx-block-coauthor-commit && git status"}'

assert_allow "git log showing coauthor history" \
  '{"command":"cd /tmp/aal-fx-block-coauthor-commit && git log --format=%b -1"}'

summary

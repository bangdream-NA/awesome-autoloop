#!/usr/bin/env bash
# 2026-07-08: enforce-conventional-commit.sh was consolidated into
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
AAL_PROJ=/tmp/aal-fx-enforce-conventional-commit
rm -rf "$AAL_PROJ"
mkdir -p "$AAL_PROJ/.claude"
: > "$AAL_PROJ/.claude/.autoloop"
git -C "$AAL_PROJ" init -q 2>/dev/null || true
export CLAUDE_PROJECT_DIR="$AAL_PROJ"
trap 'rm -rf "$AAL_PROJ"' EXIT
# ---------------------------------------------------------------------------------


# All allowed conventional formats
assert_allow "feat: simple" \
  '{"command":"cd /tmp/aal-fx-enforce-conventional-commit && git commit -m \"feat: add foo\""}'

assert_allow "fix(api): scoped" \
  '{"command":"cd /tmp/aal-fx-enforce-conventional-commit && git commit -m \"fix(api): handle null\""}'

assert_allow "refactor(web)!: breaking" \
  '{"command":"cd /tmp/aal-fx-enforce-conventional-commit && git commit -m \"refactor(web)!: drop legacy api\""}'

assert_allow "docs(readme): docs scope" \
  '{"command":"cd /tmp/aal-fx-enforce-conventional-commit && git commit -m \"docs(readme): typo fix\""}'

assert_allow "chore: simple chore" \
  '{"command":"cd /tmp/aal-fx-enforce-conventional-commit && git commit -m \"chore: bump deps\""}'

# Bad formats
assert_deny  "WIP message" \
  '{"command":"cd /tmp/aal-fx-enforce-conventional-commit && git commit -m \"WIP figuring out api\""}' \
  "conventional format"

assert_deny  "no colon" \
  '{"command":"cd /tmp/aal-fx-enforce-conventional-commit && git commit -m \"feat add foo\""}' \
  "conventional format"

assert_deny  "unknown type" \
  '{"command":"cd /tmp/aal-fx-enforce-conventional-commit && git commit -m \"woof: bark\""}' \
  "conventional format"

# Non-commit commands pass through
assert_allow "git status (no commit)" \
  '{"command":"cd /tmp/aal-fx-enforce-conventional-commit && git status"}'

assert_allow "git push (different gate)" \
  '{"command":"cd /tmp/aal-fx-enforce-conventional-commit && git push origin main"}'

# Heredoc commit (we cant parse message, skip)
assert_allow "heredoc commit — parser punts to git" \
  '{"command":"cd /tmp/aal-fx-enforce-conventional-commit && git commit -m \"$(cat <<EOF\\nfeat: foo\\nEOF\\n)\""}'

summary

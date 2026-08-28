#!/usr/bin/env bash
# Fixtures for block-claude-dir-commit.sh — blocks `git commit`/`git push` when
# .claude/ is staged. The deny branch reads live `git diff --cached`, so here we
# verify (a) command ROUTING (non git-commit/push pass through) and (b) the
# `^\.claude/` staged-name regex directly (unit-style, like the cleaned-data test).

source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/block-claude-dir-commit.sh

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
AAL_PROJ=/tmp/aal-fx-block-claude-dir-commit
rm -rf "$AAL_PROJ"
mkdir -p "$AAL_PROJ/.claude"
: > "$AAL_PROJ/.claude/.autoloop"
git -C "$AAL_PROJ" init -q 2>/dev/null || true
export CLAUDE_PROJECT_DIR="$AAL_PROJ"
trap 'rm -rf "$AAL_PROJ"' EXIT
# ---------------------------------------------------------------------------------


# --- ALLOW: non commit/push commands route straight past (exit at the grep) ---
assert_allow "git status" \
  '{"command":"git status"}'

assert_allow "pnpm install" \
  '{"command":"pnpm install"}'

assert_allow "git add (not commit/push)" \
  '{"command":"git add ."}'

# git commit / git push with nothing .claude staged in THIS cwd → pass through.
# (We can't deterministically stage .claude/ here; just prove it routes + no crash.)
assert_allow "git commit, nothing staged" \
  '{"command":"git commit -m \"docs: x\""}'

# --- Staged-name regex unit test (the deny condition: grep -q '^\.claude/') ---
STAGED_PATTERN='^\.claude/'
name_test() {
  local desc="$1"; local name="$2"; local expect="$3"  # hit|miss
  if echo "$name" | grep -qE "$STAGED_PATTERN"; then
    if [ "$expect" = "hit" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILURES+=("UNEXPECTED-HIT: $desc ($name)"); fi
  else
    if [ "$expect" = "miss" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILURES+=("EXPECTED-HIT: $desc ($name)"); fi
  fi
}

name_test ".claude/settings.json"      ".claude/settings.json"        "hit"
name_test ".claude/hooks/x.sh"          ".claude/hooks/x.sh"          "hit"
name_test "apps/web/page.tsx"           "apps/web/page.tsx"           "miss"
name_test "docs/.claude-notes.md"       "docs/.claude-notes.md"       "miss"
name_test "src/dot.claude/x"            "src/dot.claude/x"            "miss"

summary

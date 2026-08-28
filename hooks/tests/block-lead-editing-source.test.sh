#!/usr/bin/env bash
# Fixtures for block-lead-editing-source.sh — PreToolUse on Write/Edit. Blocks the
# team lead from editing app source (apps/{web,api,admin,worker,scraper}/, packages/,
# Android app/src/, gradle/) but allows harness files (.claude/, docs/, CLAUDE.md,
# hooks/, memory/, plans/, agents/, skills/, settings.json, etc.).
#
# The block branch appends to <project>/.claude/struggle-log.md; pin CLAUDE_PROJECT_DIR
# to an empty temp dir so that side-effect path doesn't exist (the hook guards on -f).

# declared then exported: `export X="$(cmd)"` masks the command's exit status (SC2155), and
# the lint lane this kit ships treats any shellcheck finding as a failure.
LLEST_DIR="$(mktemp -d 2>/dev/null || echo /tmp/llest-$$)"
export CLAUDE_PROJECT_DIR="$LLEST_DIR"

source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/block-lead-editing-source.sh

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
AAL_PROJ=/tmp/aal-fx-block-lead-editing-source
rm -rf "$AAL_PROJ"
mkdir -p "$AAL_PROJ/.claude"
: > "$AAL_PROJ/.claude/.autoloop"
git -C "$AAL_PROJ" init -q 2>/dev/null || true
export CLAUDE_PROJECT_DIR="$AAL_PROJ"
trap 'rm -rf "$AAL_PROJ"' EXIT
# ---------------------------------------------------------------------------------


# --- ALLOW: harness files ---
assert_allow ".claude hook script"   '{"file_path":"/z/Users/dev/.claude/hooks/x.sh"}'
assert_allow "docs markdown"          '{"file_path":"Z:/repo/docs/foo.md"}'
assert_allow "CLAUDE.md"              '{"file_path":"Z:/repo/CLAUDE.md"}'
assert_allow "project settings.json"  '{"file_path":"Z:/repo/.claude/settings.json"}'
assert_allow "memory file"            '{"file_path":"/z/Users/dev/.claude/projects/x/memory/foo.md"}'
assert_allow "root README"            '{"file_path":"Z:/repo/README.md"}'
assert_allow "empty file_path"        '{"tool_input":{}}'

# --- DENY: app source across both stacks ---

# assert_deny with ONE environment variable set for that invocation only. Local to this fixture:
# _lib.sh is shared with the already-delivered fixtures, and widening a shared helper for one arm
# is how a suite acquires behaviour nobody reviewed.
assert_deny_setenv() {
  local desc="$1"; local var="$2"; local val="$3"; local input="$4"; local expect_sub="${5:-}"
  local out
  out=$(printf '%s' "$input" | env "$var=$val" bash "$HOOK" 2>&1 || true)
  if printf '%s' "$out" | grep -q '"permissionDecision":"deny"'; then
    if [ -n "$expect_sub" ] && ! printf '%s' "$out" | grep -q "$expect_sub"; then
      FAIL=$((FAIL+1)); FAILURES+=("DENY-WRONG-REASON: $desc")
    else
      PASS=$((PASS+1))
    fi
  else
    FAIL=$((FAIL+1)); FAILURES+=("EXPECTED-DENY-BUT-ALLOWED: $desc (got: $(printf '%s' "$out" | head -c 120))")
  fi
}

assert_deny "example-project web page"        '{"file_path":"Z:/repo/apps/web/app/page.tsx"}'  'developer agent'
assert_deny "example-project api src"         '{"file_path":"Z:/repo/apps/api/src/index.ts"}'  'developer agent'
assert_deny "example-project package"         '{"file_path":"Z:/repo/packages/db/schema.ts"}'  'developer agent'
assert_deny "android kotlin src"      '{"file_path":"Z:/My Android App/app/src/Main.kt"}'   'developer agent'
# --- DENY: example-project Python pipeline (the data-pipeline/ gap the user caught 2026-07-19) ---
assert_deny "data-pipeline src"       '{"file_path":"Z:/repo/data-pipeline/src/example_crawler/v1/official_archive.py"}' 'developer agent'
# A test tree under a non-standard root is NOT in the shipped default globs
# (`(^|/)(src|app|apps|lib|packages|pkg|internal|cmd)/`), and widening that default here would
# block a lead editing any test file in any adopter's repo — a rule nobody specified. The gate
# publishes `AAL_APP_SRC_GLOBS` for exactly this, so the arm exercises the SEAM instead, which is
# the documented way a project with its own layout extends the protected set.
assert_deny_setenv "data-pipeline test (via the AAL_APP_SRC_GLOBS seam)" \
  AAL_APP_SRC_GLOBS '(^|/)(src|app|apps|lib|packages|pkg|internal|cmd|tests)/' \
  '{"file_path":"Z:/wt/r-newschrome/data-pipeline/tests/test_v1_news_schedule.py"}' 'developer agent'
assert_deny "data-pipeline catalog"   '{"file_path":"Z:/repo/data-pipeline/src/example_crawler/v1/catalog.py"}' 'developer agent'
# --- DENY: Windows backslash paths (2026-07-20 bypass — lead Edit of globals.css slipped) ---
assert_deny "win web globals.css"     '{"file_path":"D:\\example-project\\apps\\web\\styles\\globals.css"}' 'developer agent'
assert_deny "win web test pin"        '{"file_path":"D:\\example-project\\apps\\web\\__tests__\\r-gbp-merged-structure-review-ack.test.ts"}' 'developer agent'
assert_deny "win data-pipeline src"   '{"file_path":"D:\\example-project\\data-pipeline\\src\\example_crawler\\v1\\canonical.py"}' 'developer agent'

summary

#!/usr/bin/env bash
# Fixtures for require-tests-before-ship.sh — gates `git push` on a feature branch
# when source changed but no tests did. The diff/branch deny paths need a live repo,
# so we cover (a) ROUTING (non-push → allow) and (b) the stack-aware src-vs-test
# detection grep logic (Kotlin / TypeScript / SQL-migration) as pure unit tests.

source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/require-tests-before-ship.sh

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
AAL_PROJ=/tmp/aal-fx-require-tests-before-ship
rm -rf "$AAL_PROJ"
mkdir -p "$AAL_PROJ/.claude"
: > "$AAL_PROJ/.claude/.autoloop"
git -C "$AAL_PROJ" init -q 2>/dev/null || true
export CLAUDE_PROJECT_DIR="$AAL_PROJ"
trap 'rm -rf "$AAL_PROJ"' EXIT
# ---------------------------------------------------------------------------------


# --- ALLOW: non-push commands exit at the routing grep (line 10) ---
assert_allow "git status"  '{"command":"git status"}'
assert_allow "git commit"  '{"command":"git commit -m \"fix: y\""}'
assert_allow "gh pr view"  '{"command":"gh pr view"}'

# --- Unit: src-vs-test detection. BLOCK = source present AND zero tests. ---
# Mirrors the hook's grep -cE patterns against a synthetic changed-file list.
verdict() { # <changed-multiline> -> echoes BLOCK or OK
  local changed="$1"
  local kt_src kt_test ts_all ts_test ts_src sql_src sql_mig sql_nonmig
  kt_src=$(echo "$changed" | grep -cE '\.kt$' || true)
  kt_test=$(echo "$changed" | grep -cE 'Test\.kt$|/test/' || true)
  ts_all=$(echo "$changed" | grep -cE '\.(ts|tsx)$' || true)
  ts_test=$(echo "$changed" | grep -cE '(__tests__/|\.test\.(ts|tsx)$|\.spec\.(ts|tsx)$)' || true)
  ts_src=$((ts_all - ts_test))
  sql_src=$(echo "$changed" | grep -cE '\.sql$' || true)
  sql_mig=$(echo "$changed" | grep -cE '(migrations?/|drizzle/).*\.sql$' || true)
  sql_nonmig=$((sql_src - sql_mig))
  if { [ "$kt_src" -gt 0 ] && [ "$kt_test" -eq 0 ]; } \
     || { [ "$ts_src" -gt 0 ] && [ "$ts_test" -eq 0 ]; } \
     || { [ "$sql_nonmig" -gt 0 ] && [ "$sql_mig" -eq 0 ]; }; then
    echo BLOCK; else echo OK; fi
}
vtest() { local desc="$1" changed="$2" expect="$3"; local got; got=$(verdict "$changed");
  if [ "$got" = "$expect" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILURES+=("$desc: want $expect got $got"); fi; }

vtest "TS src, no test"       $'apps/web/lib/x.ts'                                 BLOCK
vtest "TS src + test"         $'apps/web/lib/x.ts\napps/web/__tests__/x.test.ts'   OK
vtest "TS test only"          $'apps/web/__tests__/x.test.ts'                      OK
vtest "Kotlin src, no test"   $'app/src/Main.kt'                                   BLOCK
vtest "Kotlin src + Test.kt"  $'app/src/Main.kt\napp/src/MainTest.kt'              OK
vtest "SQL schema, no migration" $'packages/db/schema.sql'                         BLOCK
vtest "SQL migration present" $'packages/db/migrations/0030_x.sql'                 OK
vtest "docs only (no src)"    $'docs/foo.md\nREADME.md'                            OK

summary

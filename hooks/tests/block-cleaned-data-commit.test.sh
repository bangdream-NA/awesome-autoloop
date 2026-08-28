#!/usr/bin/env bash
# Tests the BAD_PATTERN regex directly + the command-matching branch.
# (Full git diff scan requires staging real files; out of scope here.)

source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/block-cleaned-data-commit.sh

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
AAL_PROJ=/tmp/aal-fx-block-cleaned-data-commit
rm -rf "$AAL_PROJ"
mkdir -p "$AAL_PROJ/.claude"
: > "$AAL_PROJ/.claude/.autoloop"
git -C "$AAL_PROJ" init -q 2>/dev/null || true
export CLAUDE_PROJECT_DIR="$AAL_PROJ"
trap 'rm -rf "$AAL_PROJ"' EXIT
# ---------------------------------------------------------------------------------


# Non-commit/non-push commands pass through
assert_allow "git status" \
  '{"command":"git status"}'

assert_allow "git log" \
  '{"command":"git log -3"}'

assert_allow "pnpm install" \
  '{"command":"pnpm install"}'

# git commit / git push will invoke `git diff --cached` / `git diff origin/main...HEAD`
# When cwd has no staged dirty data, both pass naturally — we just verify hook routes
# the command + doesn't crash. Real BAD_PATTERN matches tested in unit-style below.

# Pattern-matching unit test (run pattern against synthetic file list)
BAD_PATTERN='(^|/)(canonical[^/]*\.json$|cleaned/|published/|snapshots/|.*\.dump$|.*\.sql\.gz$|.*\.parquet$|.*\.ndjson$|apps/worker/public-data/|data-pipeline/data/v1/)'

pattern_test() {
  local desc="$1"; local file="$2"; local expect="$3"  # expect=hit|miss
  if echo "$file" | grep -qE "$BAD_PATTERN"; then
    if [ "$expect" = "hit" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILURES+=("UNEXPECTED-HIT: $desc ($file)"); fi
  else
    if [ "$expect" = "miss" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILURES+=("EXPECTED-HIT: $desc ($file)"); fi
  fi
}

pattern_test "canonical.json"               "data-pipeline/data/v1/canonical.json" "hit"
pattern_test "canonical-2026.json"          "exports/canonical-2026.json"          "hit"
pattern_test "cleaned/songs.json"           "cleaned/songs.json"                   "hit"
pattern_test "published/snapshot.json"      "published/snapshot.json"              "hit"
pattern_test "snapshots/v1.tar"             "snapshots/v1.tar"                     "hit"
pattern_test "*.dump"                       "db/2026-05-25.dump"                   "hit"
pattern_test "*.sql.gz"                     "backup/db.sql.gz"                     "hit"
pattern_test "*.parquet"                    "analytics/events.parquet"             "hit"
pattern_test "*.ndjson"                     "exports/bands.ndjson"                 "hit"
pattern_test "apps/worker/public-data/"     "apps/worker/public-data/songs.json"   "hit"
pattern_test "data-pipeline/data/v1/"       "data-pipeline/data/v1/songs.json"     "hit"

# Negative cases
pattern_test "normal page.tsx"              "apps/web/page.tsx"                    "miss"
pattern_test "docs/foo.md"                  "docs/foo.md"                          "miss"
pattern_test "package.json"                 "package.json"                         "miss"
pattern_test "schema.sql (raw)"             "packages/db/schema.sql"               "miss"
pattern_test "messages/en.json"             "apps/web/messages/en.json"            "miss"

summary

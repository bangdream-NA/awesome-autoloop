#!/usr/bin/env bash
# cr-sdk-temp-cleanup — the review SDK leaves temporary files behind when a session dies mid-run, and
# nothing else ever removes them. This clears the ones old enough to be certainly orphaned, and says
# how much it freed. The age threshold is the whole design: a file from ten minutes ago may still be
# in use by a live run.
source "$(dirname "$0")/_lib.sh"
HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$HOOKS_DIR/cr-sdk-temp-cleanup.sh"

# --- portable activation context ---------------------------------------------------------------
AAL_TMP="$(mktemp -d)"
mkdir -p "$AAL_TMP/proj/.claude" "$AAL_TMP/temp"
: > "$AAL_TMP/proj/.claude/.autoloop"
AAL_TMP_N="$(aal_native "$AAL_TMP")"
export CLAUDE_PROJECT_DIR="$AAL_TMP_N/proj"
# 🔴 This one DELETES FILES. Pointed at the operator's real temp directory it would do so on every
# run of the suite — which is its job in production and emphatically not a fixture's business.
export TEMP="$AAL_TMP/temp"
export TMPDIR="$AAL_TMP/temp"
trap 'rm -rf "$AAL_TMP"' EXIT

TD="$AAL_TMP/temp"
seed() {
  rm -f "$TD"/*.tmp "$TD"/*.log 2>/dev/null || true
  printf 'old\n'    > "$TD/cr_sdk_old.tmp";     aal_touch_rel '-3 days' "$TD/cr_sdk_old.tmp"
  printf 'older\n'  > "$TD/cr_sdk_older.tmp";   aal_touch_rel '-9 days' "$TD/cr_sdk_older.tmp"
  printf 'fresh\n'  > "$TD/cr_sdk_fresh.tmp"
  printf 'other\n'  > "$TD/something-else.tmp"; aal_touch_rel '-9 days' "$TD/something-else.tmp"
  printf 'log\n'    > "$TD/cr_sdk_old.log";     aal_touch_rel '-9 days' "$TD/cr_sdk_old.log"
}
here() { [ -e "$TD/$1" ] && echo yes || echo no; }
# -----------------------------------------------------------------------------------------------

seed
out="$(printf '{}' | bash "$HOOK" 2>&1)"

# --- what it removed, and what it left ------------------------------------------------------------
# Four separate judgements, and each one is a different way to get this wrong: too old to keep, too
# young to touch, the wrong name, the wrong extension.
if [ "$(here cr_sdk_old.tmp)" = "no" ] && [ "$(here cr_sdk_older.tmp)" = "no" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("REMOVE: an orphan older than a day survived (3d=$(here cr_sdk_old.tmp) 9d=$(here cr_sdk_older.tmp))")
fi
if [ "$(here cr_sdk_fresh.tmp)" = "yes" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("KEEP-FRESH: a file created minutes ago was deleted — a live run would lose it")
fi
if [ "$(here something-else.tmp)" = "yes" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("KEEP-FOREIGN: a temp file belonging to something else was deleted")
fi
if [ "$(here cr_sdk_old.log)" = "yes" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("KEEP-OTHER-EXT: a .log with the same prefix was deleted")
fi

# --- it says what it did ---------------------------------------------------------------------------------
# A cleanup that runs silently is indistinguishable from one that is not running at all, which is how
# a disk fills up with nobody noticing.
if printf '%s' "$out" | grep -q 'cr_sdk temp cleanup'; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("REPORT: nothing was printed after removing two files (got: $(printf '%s' "$out" | head -c 120))")
fi

# --- with nothing to do it stays quiet ---------------------------------------------------------------------
rm -f "$TD"/*.tmp "$TD"/*.log 2>/dev/null || true
printf 'fresh\n' > "$TD/cr_sdk_fresh.tmp"
out="$(printf '{}' | bash "$HOOK" 2>&1)"
if [ -z "$out" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("QUIET: it spoke with nothing to remove (got: $(printf '%s' "$out" | head -c 120))")
fi

# --- outside a project that runs the convention it does not touch anything -----------------------------------
seed
out="$(CLAUDE_PROJECT_DIR="$AAL_TMP_N/not-a-project" bash "$HOOK" 2>&1 <<<'{}')"
if [ "$(here cr_sdk_older.tmp)" = "yes" ] && [ -z "$out" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("SCOPE: it deleted files outside an autoloop project (9d=$(here cr_sdk_older.tmp))")
fi

summary

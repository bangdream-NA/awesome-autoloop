#!/usr/bin/env bash
# first-run-test.sh — AC-9. Installs into a temp .claude/ and asserts every gate-required seed
# lands + the op-log seed is ls -t-resolvable + dirs materialize. Exit 0 = PASS, 1 = FAIL.
set -uo pipefail
ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
TMP=$(mktemp -d); TARGET="$TMP/.claude"
trap 'rm -rf "$TMP"' EXIT
FAIL=0
ok(){ echo "  PASS $1"; }
bad(){ echo "  FAIL $1"; FAIL=1; }

# --dry-run writes nothing
node "$ROOT/skills/install/install.mjs" --plugin-root "$ROOT" --target "$TARGET" --dry-run >/dev/null 2>&1
if [ -d "$TARGET" ]; then bad "--dry-run created $TARGET (must write nothing)"; else ok "--dry-run wrote nothing"; fi

# --apply seeds everything
node "$ROOT/skills/install/install.mjs" --plugin-root "$ROOT" --target "$TARGET" --apply >/dev/null 2>&1
for f in plan-reviews.md reviews/index.jsonl reviews/TEMPLATE.jsonl walks/TEMPLATE.md \
         autoloop-log-TEMPLATE.md BACKLOG.md code-reviews.md struggle-log.md CLAUDE.md \
         rules/common/principles.md rules/common/pipeline-discipline.md .autoloop; do
  if [ -e "$TARGET/$f" ]; then ok "seed $f"; else bad "missing seed $f"; fi
done
for d in reviews walks; do
  if [ -d "$TARGET/$d" ]; then ok "dir $d/ materialized"; else bad "missing dir $d/"; fi
done

# op-log seed is RESOLVABLE by the merge gate's grep-ALL (existence != resolvable).
# This MIRRORS the merge gate's mechanism (require-oplog-row-for-this-merge.sh: grep across ALL
# autoloop-log-*.md, not a single ls -t|head -1) — the test must reproduce the gate's OWN mechanism,
# so `ls` (not find) is deliberate here.
# shellcheck disable=SC2012
RESOLVED=$( (cd "$TARGET" && ls autoloop-log-*.md 2>/dev/null | head -1) )
if [ -n "$RESOLVED" ] && [ -f "$TARGET/$RESOLVED" ]; then
  ok "op-log grep-ALL-resolvable ($RESOLVED)"
else
  bad "op-log seed not resolved by grep-ALL 'autoloop-log-*.md'"
fi
# op-log seed is INERT (no concrete #<digits> the merge gate would read as 'logged')
if grep -qE '#[0-9]' "$TARGET/$RESOLVED" 2>/dev/null; then
  bad "op-log seed has a concrete #N (merge-gate footgun)"
else
  ok "op-log seed inert (no concrete #N)"
fi

# idempotent re-run: hand-edit a seed, re-apply, assert untouched (skip-if-exists)
echo "USER EDIT" >> "$TARGET/plan-reviews.md"
node "$ROOT/skills/install/install.mjs" --plugin-root "$ROOT" --target "$TARGET" --apply >/dev/null 2>&1
if grep -q "USER EDIT" "$TARGET/plan-reviews.md"; then
  ok "re-run preserved user edit (skip-if-exists)"
else
  bad "re-run CLOBBERED user edit"
fi

if [ "$FAIL" -eq 0 ]; then echo "RESULT: PASS"; exit 0; else echo "RESULT: FAIL"; exit 1; fi

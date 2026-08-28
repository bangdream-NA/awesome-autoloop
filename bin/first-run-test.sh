#!/usr/bin/env bash
set -uo pipefail
ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
TMP=$(mktemp -d); TARGET="$TMP/.claude"
trap 'rm -rf "$TMP"' EXIT
FAIL=0
ok(){ echo "  PASS $1"; }
bad(){ echo "  FAIL $1"; FAIL=1; }

node "$ROOT/skills/install/install.mjs" --plugin-root "$ROOT" --target "$TARGET" --dry-run >/dev/null 2>&1
if [ -d "$TARGET" ]; then bad "--dry-run created $TARGET (must write nothing)"; else ok "--dry-run wrote nothing"; fi

node "$ROOT/skills/install/install.mjs" --plugin-root "$ROOT" --target "$TARGET" --apply >/dev/null 2>&1
for f in plan-reviews.md reviews/index.jsonl reviews/TEMPLATE.jsonl walks/TEMPLATE.md \
         autoloop-log-TEMPLATE.md BACKLOG.md code-reviews.md struggle-log.md CLAUDE.md \
         .autoloop; do
  if [ -e "$TARGET/$f" ]; then ok "seed $f"; else bad "missing seed $f"; fi
done

# 🔴 The rule files are DERIVED from what ships, never named here. A hard-coded pair cannot see a
# rule template that ships and is never copied — which is what happened: the managed CLAUDE.md block
# names four files, the installer's TEMPLATE_FILES named two, and this list agreed with the
# INSTALLER rather than with the artifact, so every arm stayed green while half the discipline never
# reached an adopter's tree. The denominator has to come from templates/, not from a list.
SHIPPED_RULES=0
for r in "$ROOT"/templates/rules/common/*.md; do
  [ -e "$r" ] || continue
  SHIPPED_RULES=$((SHIPPED_RULES + 1))
  n="rules/common/$(basename "$r")"
  if [ -e "$TARGET/$n" ]; then ok "seed $n"; else bad "missing seed $n (it ships in templates/, the installer does not copy it)"; fi
done
# A glob that matched nothing would make every arm above vacuous, and vacuous reads exactly like pass.
if [ "$SHIPPED_RULES" -ge 1 ]; then
  ok "rule templates found to check ($SHIPPED_RULES)"
else
  bad "no rule template matched templates/rules/common/*.md — the arms above checked nothing"
fi
for d in reviews walks; do
  if [ -d "$TARGET/$d" ]; then ok "dir $d/ materialized"; else bad "missing dir $d/"; fi
done

# shellcheck disable=SC2012
RESOLVED=$( (cd "$TARGET" && ls autoloop-log-*.md 2>/dev/null | head -1) )
if [ -n "$RESOLVED" ] && [ -f "$TARGET/$RESOLVED" ]; then
  ok "op-log grep-ALL-resolvable ($RESOLVED)"
else
  bad "op-log seed not resolved by grep-ALL 'autoloop-log-*.md'"
fi
if grep -qE '#[0-9]' "$TARGET/$RESOLVED" 2>/dev/null; then
  bad "op-log seed has a concrete #N (merge-gate footgun)"
else
  ok "op-log seed inert (no concrete #N)"
fi

echo "USER EDIT" >> "$TARGET/plan-reviews.md"
node "$ROOT/skills/install/install.mjs" --plugin-root "$ROOT" --target "$TARGET" --apply >/dev/null 2>&1
if grep -q "USER EDIT" "$TARGET/plan-reviews.md"; then
  ok "re-run preserved user edit (skip-if-exists)"
else
  bad "re-run CLOBBERED user edit"
fi

if [ "$FAIL" -eq 0 ]; then echo "RESULT: PASS"; exit 0; else echo "RESULT: FAIL"; exit 1; fi

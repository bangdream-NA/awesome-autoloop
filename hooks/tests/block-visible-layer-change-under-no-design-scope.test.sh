#!/usr/bin/env bash
# block-visible-layer-change-under-no-design-scope — the sibling gate reads the declaration when the
# developer is DISPATCHED, and is blind to what the implementation then does. A wave can declare
# "nothing visible" in good faith and still ship a heading that went from screen-reader-only to a
# page title. This gate reads the DIFF at PR time and denies the contradiction.
source "$(dirname "$0")/_lib.sh"
HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$HOOKS_DIR/block-visible-layer-change-under-no-design-scope.mjs"

# --- portable activation context ---------------------------------------------------------------
AAL_TMP="$(mktemp -d)"
trap 'rm -rf "$AAL_TMP"' EXIT

REPO="$AAL_TMP/repo"
mkdir -p "$REPO/.claude" "$REPO/src"
REPO_N="$(aal_mkrepo "$REPO")"
: > "$REPO/.claude/.autoloop"
aal_pin_project "$REPO_N"

SCOPE_KEY=design-scope
card() { printf '%s [%s] %s · %s: %s\n' '###' 'IN-DEV' "feat/$1" "$SCOPE_KEY" "$2"; }
# -----------------------------------------------------------------------------------------------

p() { node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",cwd:process.argv[2],tool_input:{command:process.argv[1]}}))' -- "$1" "$REPO_N"; }

# --- the predicate, driven directly through the module's own export -------------------------------
# The gate exports `decide` and guards its entry point behind AAL_FIXTURE_IMPORT, which is what makes
# the table below possible: one process, every combination of declaration and diff, no git in the
# loop. The end-to-end arms further down are what prove that this predicate is actually WIRED to a
# real command — a table like this passes just as happily against a module nothing calls.
cat > "$AAL_TMP/unit.mjs" <<'UNIT'
process.env.AAL_FIXTURE_IMPORT = '1';
// The module is named by PATH and converted here rather than by the caller: a shell-style path and a
// file URL are two different things on Windows, and getting that wrong reports as "module not found",
// which reads like the gate is missing rather than like the fixture asked for it wrongly.
const { pathToFileURL } = await import('node:url');
const m = await import(pathToFileURL(process.argv[2]).href);
let pass = 0, fail = 0;
const arm = (label, input, wantDeny) => {
  const got = m.decide(input).deny;
  if (got === wantDeny) { pass++; console.log(`ok    ${label}`); }
  else { fail++; console.log(`FAIL  ${label} want=${wantDeny} got=${got}`); }
};
const NO = 'design-scope: no — data only';
const YES = 'design-scope: yes';
const tsx = ['src/widget.tsx'];

arm('css file under a no declaration',       { cardBlock: NO, changedFiles: ['src/app.css'] }, true);
arm('design tokens under a no declaration',  { cardBlock: NO, changedFiles: ['src/design-tokens.json'] }, true);
arm('i18n copy under a no declaration',      { cardBlock: NO, changedFiles: ['messages/en.json'] }, true);
arm('a className change in a component',     { cardBlock: NO, changedFiles: tsx, diffAdded: '+  <div className="mt-4">' }, true);
arm('a heading level change',                { cardBlock: NO, changedFiles: tsx, diffAdded: '+  <h2>Venues</h2>', diffRemoved: '-  <h1>Venues</h1>' }, true);
arm('visible text between tags changed',     { cardBlock: NO, changedFiles: tsx, diffAdded: '+  <p>No venues yet</p>' }, true);
arm('an element carrying text deleted',      { cardBlock: NO, changedFiles: tsx, diffRemoved: '-  <p>No venues yet</p>' }, true);

arm('a component with no visible change',    { cardBlock: NO, changedFiles: tsx, diffAdded: '+  const x = 1;' }, false);
arm('a test file is not the visible layer',  { cardBlock: NO, changedFiles: ['src/__tests__/widget.test.tsx'], diffAdded: '+  <p>x</p>' }, false);
arm('a spec file either',                    { cardBlock: NO, changedFiles: ['src/widget.spec.tsx'], diffAdded: '+  <p>x</p>' }, false);
arm('documentation is not the visible layer',{ cardBlock: NO, changedFiles: ['docs/runbooks/OPS.md'] }, false);
arm('a markdown file anywhere',              { cardBlock: NO, changedFiles: ['README.md'] }, false);
arm('server code',                           { cardBlock: NO, changedFiles: ['src/api/venues.ts'] }, false);

arm('no declaration at all is another gate', { cardBlock: '', changedFiles: ['src/app.css'] }, false);
arm('declares yes, no artifact yet',         { cardBlock: YES, changedFiles: ['src/app.css'] }, false);
arm('declares yes with an artifact',         { cardBlock: YES + ' DESIGN DELIVERED', changedFiles: ['src/app.css'] }, false);

console.log(`ARMS ${pass + fail} (pass ${pass} fail ${fail})`);
process.exit(fail === 0 ? 0 : 1);
UNIT
unit_out="$(node "$AAL_TMP/unit.mjs" "$HOOKS_DIR/block-visible-layer-change-under-no-design-scope.mjs" 2>&1)"; unit_rc=$?
unit_total="$(printf '%s\n' "$unit_out" | grep -cE '^(ok    |FAIL  )')"
unit_fail="$(printf '%s\n' "$unit_out" | grep -cE '^FAIL  ')"
if [ "$unit_rc" -eq 0 ] && [ "$unit_total" -ge 16 ] && [ "$unit_fail" -eq 0 ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  FAILURES+=("PREDICATE-TABLE: rc=$unit_rc arms=$unit_total failing=$unit_fail (tail: $(printf '%s' "$unit_out" | tail -c 200))")
fi

# --- end to end: the predicate wired to a real command, a real board and a real diff -----------------
git -C "$REPO" checkout -q -b feat/r-widget
aal_commit_file "$REPO" src/app.css 'body { color: rebeccapurple }'
card r-widget 'no — data only, nothing visible changes' > "$REPO/.claude/BACKLOG.md"
assert_deny "a css change on a no-scope branch" \
  "$(p "gh pr create --head feat/r-widget --title 'feat: widget' --body 'Refs #42'")" 'contradicts the declaration'
# The escape is a claim somebody has to write down, which is the difference between doing it and
# doing it invisibly.
assert_allow "…with the VISIBLE-OK token" \
  "$(p "gh pr create --head feat/r-widget --title 'feat: widget' --body 'Refs #42'   # VISIBLE-OK: replaced a hardcoded colour with the existing token")"
card r-widget 'yes' > "$REPO/.claude/BACKLOG.md"
printf '%s\n%s\n' "$(card r-widget yes)" "- log: DESIGN DELIVERED" > "$REPO/.claude/BACKLOG.md"
assert_allow "…or a card that declares yes with an artifact" \
  "$(p "gh pr create --head feat/r-widget --title 'feat: widget' --body 'Refs #42'")"

# --- ALLOW: everything that is not a PR being opened ---------------------------------------------------
card r-widget 'no — data only' > "$REPO/.claude/BACKLOG.md"
assert_allow "a merge, not a create" "$(p "gh pr merge 12 --squash")"
assert_allow "a push"                "$(p "git push -u origin feat/r-widget")"
assert_allow "a create with no --head" "$(p "gh pr create --title 'feat: widget' --body 'Refs #42'")"
# A branch with no card cannot contradict a declaration that does not exist.
assert_allow "a branch that is on no card" \
  "$(p "gh pr create --head feat/r-other --title 'feat: other' --body 'Refs #42'")"

summary

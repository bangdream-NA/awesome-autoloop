#!/usr/bin/env bash
set -uo pipefail

# _lib.sh is sourced for aal_pin_new_project only; this fixture keeps its own counters and runner.
source "$(dirname "$0")/_lib.sh"

HOOK="$(cd "$(dirname "$0")/.." && pwd)/block-cd-relative-write.sh"
# 🔴 Do not put an `[ -x "$HOOK" ]` guard back here. Every tracked .sh in this repository is git
# mode 100644 -- not one is 100755 -- so that guard exits 1 before the first arm on any checkout
# that honours git's mode, i.e. on ubuntu and on macOS. It was the only one of 114 HOOK= fixtures
# asserting -x, and it ran ZERO arms on both hosted POSIX lanes for the whole wave while looking
# like an ordinary red. Locally it is invisible: MSYS synthesizes an exec bit for .sh, so `[ -x ]`
# is TRUE in Git Bash (control: `[ -x README.md ]` is FALSE, so the test does discriminate).
# The bit is never consulted at runtime either -- all 117 mounts in hooks.json are `bash <path>`.

# 🔴 The gate no-ops outside an autoloop project, so without a pinned one every MUST-RED arm below
# reported "want deny, got allow" on a fresh clone (CI, and every adopter) while the gate was doing
# exactly what README.md promises. The payload paths are synthetic, so the project only has to
# exist — it is what switches the gate on, not what it judges.
AAL_TMP="$(mktemp -d)"
trap 'rm -rf "$AAL_TMP"' EXIT
aal_pin_new_project "$AAL_TMP/proj" > /dev/null

PASS=0; FAIL=0; RAN=0

run() {
  local expect="$1" label="$2" cmd="$3"
  RAN=$((RAN + 1))
  local payload out verdict
  payload=$(node -e '
    const c = process.argv[1];
    process.stdout.write(JSON.stringify({ tool_name: "Bash", tool_input: { command: c } }));
  ' "$cmd")
  out=$(printf '%s' "$payload" | bash "$HOOK" 2>/dev/null || true)
  if printf '%s' "$out" | grep -q '"permissionDecision":"deny"'; then verdict=deny; else verdict=allow; fi

  if [ "$verdict" = "$expect" ]; then
    PASS=$((PASS + 1)); printf '  ok    [%s] %s\n' "$expect" "$label"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  [want %s, got %s] %s\n      cmd: %s\n' "$expect" "$verdict" "$label" "$cmd"
  fi
}

echo "== MUST-RED: the PRODUCTION payload harness refused on 2026-08-14 =="
run deny "production: cd .state then rm three relative .last files" \
  'set -o pipefail
cd ~/.claude/hooks/.state
rm session-learnings-smoke-20260814-a.last session-learnings-smoke-20260814-b.last session-learnings-smoke-default-arm.last
echo "cleanup done"'

echo "== MUST-RED: the same shape, other write verbs and separators =="
run deny "cd && rm relative"            'cd /z/my-project && rm stale.txt'
run deny "cd ; mv relative"             'cd /z/my-project; mv a.txt b.txt'
run deny "cd && cp relative"            'cd /z/wt/r-foo && cp out.json backup.json'
run deny "cd && mkdir relative"         'cd /z/my-project && mkdir newdir'
run deny "cd && rm -rf relative dir"    'cd /z/my-project && rm -rf build'
run deny "cd && touch relative"         'cd /srv/app && touch marker.flag'

echo "== MUST-GREEN: the CORRECTED form (this is what the denial text tells you to write) =="
run allow "absolute write target, no cd" \
  'rm "Z:/Users/dev/.claude/hooks/.state/session-learnings-smoke-20260814-a.last"'
run allow "cd + write to a POSIX-absolute target" 'cd /z/my-project && rm /tmp/stale.txt'
run allow "cd + write to a Windows-absolute target" 'cd /z/my-project && rm Z:/Users/dev/x.log'
run allow "git -C, cwd-independent"       'git -C /z/my-project status --porcelain'

echo "== MUST-GREEN: read-only after cd is not this gate's target =="
run allow "cd && git status"            'cd /z/my-project && git status'
run allow "cd && cat"                   'cd /z/my-project && cat README.md'
run allow "cd && ls piped"              'cd /z/my-project && ls -1 | grep foo'

echo "== MUST-GREEN: documented exemptions =="
run allow "escape token"                'cd /z/x && rm foo.txt # CD-WRITE-OK: one-off fixture artifact, directory created this turn'
run allow "scratchpad destination"      'cd /z/Users/dev/AppData/Local/Temp/claude/scratchpad && rm out.json'
run allow "heredoc (pattern is data)"   'cat <<EOF > /tmp/x
cd /foo && rm bar.txt
EOF'
run allow "no cd at all"                'rm stale.txt'

echo "== ARM 2 MUST-RED: the PRODUCTION payloads harness prompted on 2026-08-15 =="
# The production payload, verbatim: read-only, and it still fell through to a manual confirmation.
run deny "production: R= assigned then \$R/ used as path" \
  'R=/z/Users/dev/.claude
ls -la "$R/hooks/require-dod-verdict-quotes-card-problem.mjs" 2>&1 | sed '\''s/^/  /'\'''
# The second production payload of the same day: a path built out of an environment variable.
run deny "production: \$CLAUDE_CODE_SESSION_ID/ in a path" \
  'cat "/z/Users/dev/.claude/teams/$CLAUDE_CODE_SESSION_ID/config.json" 2>&1 | head -c 400'
run deny "braced form \${DIR}/file"     'DIR=/z/x; cat "${DIR}/file.txt"'
# A third production payload. The first version of ARM 2 only judged "the variable comes BEFORE the
#    slash", and this one is `tests/"$f"` — the variable comes AFTER it, so it was missed.
#    The classifier reported a DIFFERENT trigger word for it: `Contains shell syntax (string) that
#    cannot be statically analyzed`. A gate only recognises the shapes it has met — this arm IS that other shape.
run deny "production: var AFTER the slash + \$( ) assigned then used" \
  'ls -1 /z/Users/dev/.claude/hooks/tests/ | grep -i "loose-ends" | sed '\''s/^/  /'\''
echo "---"
f=$(ls -1 /z/Users/dev/.claude/hooks/tests/ | grep -i "loose-ends" | head -1)
if [ -n "$f" ]; then
  case "$f" in
    *.mjs) node /z/Users/dev/.claude/hooks/tests/"$f" 2>&1 | tail -14 ;;
  esac
fi'
# 2b on its own: no slash adjacency anywhere, only "assigned from a command substitution, then expanded".
run deny "2b alone: X=\$(…) then \$X, no slash adjacency" \
  'f=$(ls -1 /z/Users/dev/.claude/hooks); echo "$f" | head -3'
# A fourth production payload. The reason the harness printed for it was `Path traverses a
#    Cygwin-emulated symlink`, and that path contained zero symlinks.
#    The loop variable `$h` is used only as a grep PATTERN and touches no `/`, so neither 2a nor 2b reaches it — that is 2c's target.
run deny "production: for-loop var used as a grep pattern" \
  'for h in block-spec-branch-push.sh block-lead-plan-approval-response.sh; do
  printf "  %-46s " "$h"
  grep -l "$h" /z/Users/dev/.claude/agents/*.md 2>/dev/null | sed '\''s#.*/##'\'' | tr '\''\n'\'' '\'' '\''
  echo
done'
run deny "2c: while read var expanded" \
  'ls -1 /z/Users/dev/.claude/hooks | while read -r n; do echo "hook=$n"; done'

echo "== ARM 2 MUST-GREEN: every carve-out the header promises =="
# (a) the form the principles explicitly recommend — blocking it would make the rule contradict its own remedy.
run allow "carve-out (a) redirect to \$TMP"   'pnpm build > "$TMP/out" 2>&1; rc=$?'
# (b) given by the environment, with no literal alternative.
run allow "carve-out (b) \$HOME/ path"        'ls -la "$HOME/.claude"'
# This arm went from GREEN to RED, and that was a DESIGN CHANGE, not a regression. It used to read
#    `run allow "carve-out (c) loop var, no slash"`, on the reasoning that blocking loops adds an
#    unrequested constraint — an assumption. The same shape measurably still prompted, while the literal-expanded form did not.
run deny  "ARM 2c: loop var expanded (was allow until 2026-08-15)" \
  'for f in *.md; do wc -c "$f"; done'
# (c) still allowed after the narrowing: an expansion that touches no `/` AND is not inside a loop — the rc-capture form the principles recommend.
run allow "carve-out (c) rc capture, no loop"  'pnpm -r test --run > "$TMP/out" 2>&1; rc=$?; echo "rc=$rc"'
# A loop that does not expand its loop variable ⇒ the iteration is unrelated to any path ⇒ allow.
run allow "loop without expanding its var"     'for i in 1 2 3; do date -u; done'
# (d) command substitution plus $PATH — this is the PATH fix the pipeline discipline recommends.
run allow "carve-out (d) \$(cd …) and \$PATH" 'PATH="$(cd "$dir" && pwd):$PATH"'
run allow "escape token VAR-PATH-OK"          'D=/z/x; ls "$D/y" # VAR-PATH-OK: value came from the previous measurement, no literal alternative'
# The prescribed correct form has to be clear all the way through, or this gate has no way out.
run allow "the prescribed fix: literal abs path" \
  'ls -la /z/Users/dev/.claude/hooks/block-future-timestamp.mjs'

echo "== REACHABILITY CONTROL: an empty command must not crash or deny =="
run allow "empty command"               ''

echo
printf '%d ran, %d passed, %d failed\n' "$RAN" "$PASS" "$FAIL"
[ "$RAN" -eq $((PASS + FAIL)) ] || { echo "arm accounting mismatch"; exit 1; }
[ "$FAIL" -eq 0 ] || exit 1
exit 0

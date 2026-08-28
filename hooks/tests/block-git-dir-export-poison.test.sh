#!/usr/bin/env bash
# block-git-dir-export-poison — an exported GIT_DIR redirects EVERY bare `git` in that shell,
# including the ones inside scripts it calls, and it overrides `git -C`. The gate denies the export
# and the env-prefix-into-a-script form, and yields to an explicit token.
source "$(dirname "$0")/_lib.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$HERE/../block-git-dir-export-poison.sh"

# --- portable activation context ---------------------------------------------------------------
AAL_PROJ=/tmp/aal-fx-block-git-dir-export-poison
rm -rf "$AAL_PROJ"; mkdir -p "$AAL_PROJ/.claude"; : > "$AAL_PROJ/.claude/.autoloop"
export CLAUDE_PROJECT_DIR="$AAL_PROJ"
trap 'rm -rf "$AAL_PROJ"' EXIT
# -----------------------------------------------------------------------------------------------

p() { node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:process.argv[1]}}))' -- "$1"; }

# --- DENY: the shapes that outlive the command they appear on ------------------------------------
assert_deny "export GIT_DIR"            "$(p "export GIT_DIR=/tmp/x/.git && git status")"        'must not be exported'
assert_deny "export GIT_WORK_TREE"      "$(p "export GIT_WORK_TREE=/tmp/wt/x && bash t.sh")"     'must not be exported'
assert_deny "export after a cd"         "$(p "cd /tmp && export GIT_DIR=/tmp/y/.git && git init")" 'must not be exported'
assert_deny "assign, then export"       "$(p "GIT_DIR=/tmp/x/.git; export GIT_DIR; git log")"    'must not be exported'
# The env-prefix form is a deny only when the command it prefixes is NOT git: git consumes the
# variable itself and nothing downstream inherits it, whereas a shell script passes it on to every
# git call inside.
assert_deny "env prefix into a script"  "$(p "GIT_DIR=/tmp/x/.git bash scripts/provision/test.sh")" 'must not be exported'
assert_deny "env prefix into sh, two vars" "$(p "GIT_DIR=/tmp/x GIT_WORK_TREE=/tmp/y sh run.sh")"  'must not be exported'

# --- ALLOW: the prescribed shapes ------------------------------------------------------------------
assert_allow "git -C, exporting nothing" "$(p "git -C /tmp/wt/foo status --porcelain")"
assert_allow "env prefix into git itself" "$(p "GIT_DIR=/tmp/x/.git git rev-parse --git-dir")"
assert_allow "env prefix into git by absolute path" "$(p "GIT_DIR=/tmp/x/.git /usr/bin/git log -1")"
assert_allow "the env -u cleansing form" "$(p "env -u GIT_DIR -u GIT_WORK_TREE git -C /tmp/f status")"
assert_allow "an unrelated export"       "$(p "export PYTHONIOENCODING=utf-8 && python x.py")"

# --- ALLOW: the same bytes as DATA ------------------------------------------------------------------
assert_allow "quoted inside a grep"      "$(p "grep -rn 'export GIT_DIR=' docs/")"
assert_allow "inside a double-quoted echo" "$(p "echo \"never export GIT_DIR=/tmp/... under WSL\" >> notes.md")"

# --- ALLOW: the documented escape ---------------------------------------------------------------------
assert_allow "the GIT-DIR-EXPORT-OK token" \
  "$(p "export GIT_DIR=/tmp/sandbox/.git # GIT-DIR-EXPORT-OK: throwaway clone, nothing else runs in this shell")"

# --- the gate ships its own predicate self-test; run it and read its own counters -----------------
# Not a duplicate of the arms above: those go through stdin and the wrapper, this one exercises the
# exported `verdict()` directly, including two PINNED false positives that are deliberate. The pass
# count is DERIVED from its output rather than hardcoded, so adding an arm there cannot silently
# shrink what this checks — but a FAILING arm, or an empty run, reddens here.
selftest_out="$(node "$HERE/../block-git-dir-export-poison.mjs" --self-test 2>&1)"; selftest_rc=$?
armline="$(printf '%s' "$selftest_out" | grep -oE 'ARMS[[:space:]]+[0-9]+ \(pass [0-9]+ · fail [0-9]+\)' | tail -1)"
armtotal="$(printf '%s' "$armline" | grep -oE 'ARMS[[:space:]]+[0-9]+' | grep -oE '[0-9]+')"
armpass="$(printf '%s' "$armline" | grep -oE 'pass [0-9]+' | grep -oE '[0-9]+')"
if [ "$selftest_rc" -eq 0 ] && [ -n "$armtotal" ] && [ "$armtotal" -ge 1 ] && [ "$armpass" = "$armtotal" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  FAILURES+=("SELF-TEST: rc=$selftest_rc summary='$armline' (tail: $(printf '%s' "$selftest_out" | tail -c 120))")
fi

summary

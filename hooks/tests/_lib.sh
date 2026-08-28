#!/usr/bin/env bash

PASS=0
FAIL=0
FAILURES=()

export AAL_GATE_DENIALS_OFF=1

# 🔴 Pin which repository a gate believes it is looking at. Gates that resolve "the project"
# go through lib/is-autoloop-lead.mjs, whose first probe is the SESSION id — and that falls back to
# CLAUDE_CODE_SESSION_ID from the ambient environment. Inside a real installation the lead marker
# then answers with the operator's actual repo, so a fixture that only sets cwd is quietly asking
# about somebody else's spec directory: its arms pass or fail according to what happens to be on
# disk over there, and on a clean machine they would be vacuous instead. Both variables are the
# library's own documented seam, so pinning them is what an adopter would do too.
aal_pin_project() { # $1 = repo path in node's spelling
  export AAL_AUTOLOOP_LEAD=1
  export AAL_LEAD_REPO="$1"
  export AAL_DEFAULT_REPO="$1"
  export CLAUDE_PROJECT_DIR="$1"
}

# Two views of a path. Several gates ask the filesystem or `git` a question from node, and on
# Windows node resolves a shell-style `/tmp/...` path against the drive root instead of against the
# shell's temp dir — the gate then finds nothing and declines to fire, which an arm reports as
# EXPECTED-DENY-BUT-ALLOWED. `pwd -W` is a no-op on Linux and macOS, so the fallback keeps fixtures
# portable.
aal_native() { (cd "$1" && pwd -W 2>/dev/null || printf '%s' "$1"); }

# 🔴 Relative timestamps that survive BSD. `date -u -d '-2 hours'` is a GNU extension: macOS date
# rejects the flag outright (`date: illegal option -- d`), so on that lane the substitution yielded
# an EMPTY string. Empty does not reliably redden — three fixtures wrote a garbage stamp into their
# board and their arms passed anyway, which asserts nothing while reading byte-identical to a
# correct run. That is worse than the fixtures that failed, because nothing reports it.
#
# Both platforms DO agree on `date -u +%s` and on formatting an ABSOLUTE instant — GNU spells that
# `-d @<epoch>`, BSD spells it `-r <epoch>`. So the offset is resolved to seconds in the shell and
# only the absolute instant is handed to date. The two spellings sit on ONE line deliberately: a
# GNU-only flag with its BSD twin on the same line is exactly the shape posix-utility-flags.test.mjs
# recognises as a fallback, and the shape check-stale-agents.sh:51 already ships.
aal_epoch_rel() { # $1 = "<signed-count> <unit>", e.g. "-2 hours" / "+7 days"; prints an epoch
  local count="${1%% *}" unit="${1#* }" secs
  case "$unit" in
    second|seconds) secs=1 ;;
    minute|minutes) secs=60 ;;
    hour|hours)     secs=3600 ;;
    day|days)       secs=86400 ;;
    *) echo "FIXTURE-SETUP-FAILED: aal_epoch_rel does not know the unit '$unit' in '$1'" >&2; return 1 ;;
  esac
  printf '%s' "$(( $(date -u +%s) + count * secs ))"
}

aal_date_rel() { # $1 = "<signed-count> <unit>", $2 = a date format, e.g. "+%Y-%m-%dT%H:%M:%SZ"
  local at out
  at="$(aal_epoch_rel "$1")" || return 1
  out="$(date -u -d "@$at" "$2" 2>/dev/null || date -u -r "$at" "$2" 2>/dev/null)"
  # An empty stamp is the failure this helper exists to remove, so it is never returned silently.
  # The caller reads this through `$(...)`, which discards rc — so the standing guard is the
  # behavioural arm in posix-utility-flags.test.mjs, and this line is what names the cause in a log.
  [ -n "$out" ] || { echo "FIXTURE-SETUP-FAILED: no portable date formatter (tried -d @$at and -r $at)" >&2; return 1; }
  printf '%s' "$out"
}

aal_touch_rel() { # $1 = "<signed-count> <unit>", $2.. = files to stamp
  local spec="$1" at stamp; shift
  at="$(aal_epoch_rel "$spec")" || return 1
  # `touch -d '<relative>'` is the same GNU-only extension; `touch -t CCYYMMDDhhmm.SS` is POSIX.
  # 🔴 `touch -t` reads its argument as LOCAL time, so the stamp is formatted WITHOUT `-u`. Building
  # it with `date -u` instead puts the mtime off by the host's UTC offset — caught here at +8h on a
  # UTC+8 machine, and structurally invisible on a CI runner, which is UTC and where the two agree.
  stamp="$(date -d "@$at" +%Y%m%d%H%M.%S 2>/dev/null || date -r "$at" +%Y%m%d%H%M.%S 2>/dev/null)"
  [ -n "$stamp" ] || { echo "FIXTURE-SETUP-FAILED: no portable date formatter for touch (@$at)" >&2; return 1; }
  touch -t "$stamp" "$@"
}

# 🔴 Pinning alone is not enough: lib/activation.sh looks for a MARKER FILE inside the pinned
# directory, and a directory without one is "not an autoloop project" — every gate then exits 0 in
# silence and every must-deny arm reads EXPECTED-DENY-BUT-ALLOWED with EMPTY output. On a developer
# machine the marker is usually found anyway, because `git rev-parse --git-common-dir` in a WORKTREE
# answers with the MAIN checkout, which has one; a fresh clone (CI, and every adopter) has neither,
# so the same fixture is green here and red there for a reason that has nothing to do with the gate.
# This creates the marker AND pins the project, then proves the predicate agrees before any arm runs.
aal_pin_new_project() { # $1 = directory to create the project in; prints it in node's spelling
  mkdir -p "$1/.claude"
  : > "$1/.claude/.autoloop"
  local n; n="$(aal_native "$1")"
  aal_pin_project "$n"
  # Entrance control, in the predicate's own words: without it a pin that lands in the wrong
  # spelling leaves every arm vacuous, and a vacuous arm is byte-identical to a gate that fired.
  if ! ( . "$(dirname "${BASH_SOURCE[0]}")/../lib/activation.sh"; aal_is_autoloop_project ); then
    echo "FIXTURE-SETUP-FAILED: aal_is_autoloop_project is false after pinning $n" >&2
    exit 1
  fi
  printf '%s' "$n"
}

# A throwaway repository for the gates that shell out to git. Prints the path in node's spelling.
# `origin/main` is a local ref: these gates only READ it, and a fixture needing a real remote would
# need the network before it could assert anything at all. Everything is `git -C` — exporting
# GIT_DIR would redirect every bare git call in the shell that sourced this file, the suite runner
# included.
aal_mkrepo() { # $1 = directory to create
  mkdir -p "$1"
  git -C "$1" init -q -b main
  git -C "$1" config user.email fixture@example.invalid
  git -C "$1" config user.name  fixture
  printf 'seed\n' > "$1/README.md"
  git -C "$1" add README.md
  git -C "$1" -c commit.gpgsign=false commit -qm seed
  git -C "$1" update-ref refs/remotes/origin/main HEAD
  aal_native "$1"
}

aal_commit_file() { # $1 = repo dir, $2 = path within it, $3 = content
  mkdir -p "$(dirname "$1/$2")"
  printf '%s\n' "$3" > "$1/$2"
  git -C "$1" add "$2"
  git -C "$1" -c commit.gpgsign=false commit -qm "add $2"
}

# A gate is either a shell script or an ES module, and running one with the other's interpreter
# fails in a way that reads like the gate ALLOWING: `bash gate.mjs` dies on `import:` with no deny
# token in its output, which is byte-for-byte what a gate that decided not to fire looks like on the
# assert_deny side. Dispatch on the extension so a fixture can point at whichever file the gate is.
aal_run_hook() {
  case "$HOOK" in
    *.mjs) node "$HOOK" ;;
    *)     bash "$HOOK" ;;
  esac
}

# 🔴 The deny matcher tolerates whitespace around the colon. Five shipped gates emit PRETTY-PRINTED
# JSON (`"permissionDecision": "deny"`), and a matcher pinned to the compact spelling reads those
# as ALLOW — a correct gate scored as a hole, in the helper every fixture depends on. Measured on
# block-spec-branch-push: the gate denied, the arm reported EXPECTED-DENY-BUT-ALLOWED, and the
# denial text was visible in the very output the assertion had just rejected.
# ⚠️ This widening makes assert_deny say "deny" MORE often, so its load-bearing control is the
# opposite arm: a gate that ALLOWS must still be reported as EXPECTED-DENY-BUT-ALLOWED. That arm
# lives in lib-assert-allow.test.sh beside the assert_allow ones.
assert_deny() {
  local desc="$1"; local input="$2"; local expect_sub="${3:-}"
  local out
  out=$(echo "$input" | aal_run_hook 2>&1 || true)
  if echo "$out" | grep -qE '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
    if [ -n "$expect_sub" ] && ! echo "$out" | grep -q "$expect_sub"; then
      FAIL=$((FAIL+1))
      FAILURES+=("DENY-WRONG-REASON: $desc (got: $(echo "$out" | head -c 150))")
    else
      PASS=$((PASS+1))
    fi
  else
    FAIL=$((FAIL+1))
    FAILURES+=("EXPECTED-DENY-BUT-ALLOWED: $desc (got: $(echo "$out" | head -c 150))")
  fi
}

# assert_allow requires a WELL-FORMED allow, not merely the absence of a deny.
#
# The obvious version — `out=$(... || true)` plus `grep -qv deny` — is satisfied by ABSENCE, so a
# gate that crashed, a gate that never ran, and a gate that printed nothing all scored PASS.
# assert_deny needs a POSITIVE match and therefore reddens correctly on a crash; that asymmetry is
# the whole defect. Three things are checked here, in order:
#   1. rc == 0            (captured separately; `|| true` would swallow it)
#   2. stdout is EITHER empty OR a JSON OBJECT   (a stack trace on stdout fails this)
#   3. if it is an object, it carries no deny
#
# Empty stdout is a LEGITIMATE allow in this kit — the shell gates allow by exiting 0 and saying
# nothing, while the .mjs gates write `{}`. A first version of this helper rejected empty output
# and reddened three arms of block-autoloop-on-board-drift.test.sh, all of them correct allows.
# rc is what separates "allowed silently" from "crashed": a crash is rc != 0.
# stderr is kept out of the JSON check and only reported on failure, so a gate that logs to stderr
# is not punished for it.
assert_allow() {
  local desc="$1"; local input="$2"
  local out err rc
  err="$(mktemp)"
  out=$(echo "$input" | aal_run_hook 2>"$err")
  rc=$?
  local errtxt; errtxt="$(head -c 150 "$err" 2>/dev/null)"; rm -f "$err"

  if [ "$rc" -ne 0 ]; then
    FAIL=$((FAIL+1))
    FAILURES+=("ALLOW-BUT-GATE-EXITED-$rc: $desc (stderr: $errtxt)")
    return
  fi
  if [ -n "$out" ] && ! printf '%s' "$out" | node -e '
    let s = ""; process.stdin.on("data", (c) => { s += c; });
    process.stdin.on("end", () => {
      try { const j = JSON.parse(s); process.exit(j && typeof j === "object" && !Array.isArray(j) ? 0 : 1); }
      catch { process.exit(1); }
    });' 2>/dev/null; then
    FAIL=$((FAIL+1))
    FAILURES+=("ALLOW-BUT-NOT-A-JSON-OBJECT: $desc (stdout: $(printf '%s' "$out" | head -c 150)) (stderr: $errtxt)")
    return
  fi
  if printf '%s' "$out" | grep -qE '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
    FAIL=$((FAIL+1))
    FAILURES+=("EXPECTED-ALLOW-BUT-DENIED: $desc (got: $(printf '%s' "$out" | head -c 150))")
    return
  fi
  PASS=$((PASS+1))
}

summary() {
  local name
  name="$(basename "${BASH_SOURCE[1]:-test}")"
  if [ "$FAIL" -eq 0 ]; then
    echo "  $name: PASS ($PASS/$PASS)"
    return 0
  else
    echo "  $name: FAIL ($PASS pass, $FAIL fail)"
    for f in "${FAILURES[@]}"; do
      echo "    - $f"
    done
    return 1
  fi
}


assert_fires() {
  local desc="$1"; local input="$2"; local expect_sub="${3:-}"
  local out
  out=$(echo "$input" | aal_run_hook 2>&1 || true)
  if [ -z "$out" ]; then
    FAIL=$((FAIL+1))
    FAILURES+=("EXPECTED-FIRE-BUT-SILENT: $desc")
  elif [ -n "$expect_sub" ] && ! echo "$out" | grep -q "$expect_sub"; then
    FAIL=$((FAIL+1))
    FAILURES+=("FIRED-WRONG-CONTENT: $desc (got: $(echo "$out" | head -c 150))")
  else
    PASS=$((PASS+1))
  fi
}

# Stop-channel gates say "nothing to report" in two different ways: some print nothing, others print
# an empty JSON object. assert_silent demands an empty stream, so pointing it at the second kind
# reports every quiet arm as a firing gate — six at once, the first time this was tried. This helper
# accepts either spelling and nothing else.
assert_quiet() {
  local desc="$1"; local input="$2"
  local out
  out=$(echo "$input" | aal_run_hook 2>&1 || true)
  if [ -z "$out" ] || [ "$out" = "{}" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILURES+=("EXPECTED-QUIET-BUT-FIRED: $desc (got: $(echo "$out" | head -c 150))")
  fi
}

assert_silent() {
  local desc="$1"; local input="$2"
  local out
  out=$(echo "$input" | aal_run_hook 2>&1 || true)
  if [ -n "$out" ]; then
    FAIL=$((FAIL+1))
    FAILURES+=("EXPECTED-SILENT-BUT-FIRED: $desc (got: $(echo "$out" | head -c 150))")
  else
    PASS=$((PASS+1))
  fi
}

_FAKE_GH_DIR=""
fake_gh_start() {
  _FAKE_GH_DIR=$(mktemp -d)
  cat > "$_FAKE_GH_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
# Fake `gh` for fixture tests — implements `pr view <N> --json state,mergedAt` AND
# `pr list --repo ... --state merged/open ...` (extended 2026-07-18, AC10 fixture support).
case "$*" in
  "pr view "*"--json state,mergedAt")
    printf '%s' "${FAKE_GH_RESPONSE:-}"
    exit "${FAKE_GH_EXIT:-0}"
    ;;
  "pr list --repo "*"--state merged"*)
    printf '%s' "${FAKE_GH_MERGED_JSON:-[]}"
    exit "${FAKE_GH_LIST_EXIT:-0}"
    ;;
  "pr list --repo "*"--state open"*)
    printf '%s' "${FAKE_GH_OPEN_JSON:-[]}"
    exit "${FAKE_GH_LIST_EXIT:-0}"
    ;;
  *) exit 1 ;;
esac
GHEOF
  chmod +x "$_FAKE_GH_DIR/gh"
  cat > "$_FAKE_GH_DIR/gh.cmd" <<'CMDEOF'
@echo off
bash "%~dp0gh" %*
CMDEOF
  export PATH="$_FAKE_GH_DIR:$PATH"
}
fake_gh_stop() {
  [ -n "$_FAKE_GH_DIR" ] && rm -rf "$_FAKE_GH_DIR" 2>/dev/null
  _FAKE_GH_DIR=""
}

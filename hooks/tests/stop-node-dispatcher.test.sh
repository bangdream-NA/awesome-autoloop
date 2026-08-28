#!/usr/bin/env bash
# stop-node-dispatcher — the single Stop mount that fans out to the end-of-turn checks, so a session
# pays for one process instead of seven. What it owes: run them in order, forward the FIRST one that
# speaks, treat an empty object as silence, and survive a delegate that is not installed.
source "$(dirname "$0")/_lib.sh"
HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$HOOKS_DIR/stop-node-dispatcher.mjs"

# --- portable activation context ---------------------------------------------------------------
AAL_TMP="$(mktemp -d)"
REPO="$AAL_TMP/repo"
mkdir -p "$REPO/.claude" "$AAL_TMP/home/.claude/hooks"
REPO_N="$(aal_mkrepo "$REPO")"
: > "$REPO/.claude/.autoloop"
AAL_TMP_N="$(aal_native "$AAL_TMP")"
aal_pin_project "$REPO_N"
# 🔴 The delegates are resolved under the HOME directory, with no list seam — so pointing HOME at a
# sandbox is the only way to exercise the dispatcher rather than the seven real checks. It also keeps
# the run from reading the operator's own state, and it is what makes "a delegate that is not
# installed" reachable at all: the sandbox starts with none of them present.
export HOME="$AAL_TMP_N/home"
export USERPROFILE="$AAL_TMP_N/home"
trap 'rm -rf "$AAL_TMP"' EXIT

DHOOKS="$AAL_TMP/home/.claude/hooks"
# A board with nothing to say, so the dispatcher's own checks stay quiet and the arms below are about
# the fan-out rather than about a card.
printf '%s\n' '# board' > "$REPO/.claude/$(printf '%s%s' 'BACK' 'LOG.md')"

speaker() { # $1 = delegate name, $2 = what it says
  node -e 'const fs=require("fs");fs.writeFileSync(process.argv[1], "process.stdout.write(JSON.stringify({ decision: \"block\", reason: " + JSON.stringify(process.argv[2]) + " }));\n");' \
    -- "$DHOOKS/$1.mjs" "$2"
}
silent() { printf "process.stdout.write('{}');\n" > "$DHOOKS/$1.mjs"; }
clear_delegates() { rm -f "$DHOOKS"/*.mjs; }
p() { node -e 'process.stdout.write(JSON.stringify({session_id:"11111111-2222-3333-4444-555555555555"}))'; }
run() { p | node "$HOOK" 2>&1; }
# -----------------------------------------------------------------------------------------------

# --- with none of them installed, it says nothing ------------------------------------------------------
clear_delegates
out="$(run)"
if [ -z "$out" ] || [ "$out" = "{}" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("EMPTY: with no delegates present it still spoke (got: $(printf '%s' "$out" | head -c 140))")
fi

# --- a delegate that speaks is forwarded ------------------------------------------------------------------
clear_delegates
speaker require-verdict-driven-forward 'STAND-IN: the verdict check spoke'
out="$(run)"
if printf '%s' "$out" | grep -q 'STAND-IN: the verdict check spoke'; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("FORWARD: the delegate's message did not come back (got: $(printf '%s' "$out" | head -c 140))")
fi

# --- an empty object is silence, not an answer --------------------------------------------------------------
# This is the distinction the whole chain runs on: a delegate that prints `{}` has nothing to say, and
# reading that as an answer would stop the chain at the first quiet check and hide every one after it.
clear_delegates
silent require-dod-followthrough
speaker require-askuser-when-usergated 'STAND-IN: the later check spoke'
out="$(run)"
if printf '%s' "$out" | grep -q 'STAND-IN: the later check spoke'; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("EMPTY-IS-SILENCE: a quiet delegate stopped the chain (got: $(printf '%s' "$out" | head -c 140))")
fi

# --- the FIRST speaker wins ------------------------------------------------------------------------------------
# Two messages would leave a reader with two instructions and no ordering between them.
clear_delegates
speaker require-dod-followthrough 'STAND-IN: the first check spoke'
speaker require-askuser-when-usergated 'STAND-IN: the second check spoke'
out="$(run)"
if printf '%s' "$out" | grep -q 'STAND-IN: the first check spoke' && ! printf '%s' "$out" | grep -q 'the second check spoke'; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("FIRST-WINS: (got: $(printf '%s' "$out" | head -c 160))")
fi

# --- a delegate that crashes does not take the mount down ----------------------------------------------------------
# Every other end-of-turn check would go with it, silently, and the session would look clean.
clear_delegates
printf 'throw new Error("stand-in crash");\n' > "$DHOOKS/require-dod-followthrough.mjs"
speaker require-askuser-when-usergated 'STAND-IN: reached past the crash'
out="$(run)"
if printf '%s' "$out" | grep -q 'STAND-IN: reached past the crash'; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("CRASH-TOLERANCE: a broken delegate stopped the chain (got: $(printf '%s' "$out" | head -c 160))")
fi

# --- outside a project it resolves, it does nothing at all ------------------------------------------------------------
clear_delegates
speaker require-verdict-driven-forward 'STAND-IN: should not be reached'
out="$(p | AAL_AUTOLOOP_LEAD='' AAL_LEAD_REPO='' AAL_DEFAULT_REPO='' CLAUDE_PROJECT_DIR="$AAL_TMP_N/not-a-project" node "$HOOK" 2>&1)"
if [ -z "$out" ] || [ "$out" = "{}" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("SCOPE: it dispatched with no project resolved (got: $(printf '%s' "$out" | head -c 140))")
fi

summary

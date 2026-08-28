#!/usr/bin/env bash
# bash-dev-env-preflight — the same fan-out as the ledger dispatcher, for the commands that touch a
# development environment: worktrees, installs, and a test runner that can silently load the wrong
# source tree. It owes routing, verbatim forwarding, and a cheap exit for everything else.
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/bash-dev-env-preflight.sh

# --- portable activation context ---------------------------------------------------------------
AAL_PROJ="$(mktemp -d)"
mkdir -p "$AAL_PROJ/.claude"
: > "$AAL_PROJ/.claude/.autoloop"
AAL_PROJ_N="$(aal_native "$AAL_PROJ")"
export CLAUDE_PROJECT_DIR="$AAL_PROJ_N"
trap 'rm -rf "$AAL_PROJ"' EXIT

# Synthetic, and named through the environment rather than hardcoded: the gate behind this
# dispatcher takes both as regexes, which is what lets an adopter point it at their own layout.
export AAL_MAIN_REPO='/synthetic-main-checkout'
export AAL_WORKTREE_ROOT='/synthetic-wt/'
# -----------------------------------------------------------------------------------------------

p() { # $1 = command, $2 = cwd
  node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:process.argv[1]},cwd:process.argv[2]}))' -- "$1" "${2:-/somewhere}"
}

# --- DENY: the payload reaches the gate behind the dispatcher -------------------------------------
assert_deny "an install in the shared checkout" \
  "$(p "pnpm install" "/synthetic-main-checkout/apps/web")" 'BLOCKED'
assert_deny "pnpm add, same place" \
  "$(p "pnpm add left-pad" "/synthetic-main-checkout")" 'BLOCKED'

# --- ALLOW: the same verb where it belongs -----------------------------------------------------------
assert_allow "an install inside a worktree" "$(p "pnpm install" "/synthetic-wt/r-widget")"
assert_allow "the documented escape"        "$(p "pnpm install   # ALLOW_MAIN_INSTALL: bootstrapping on purpose" "/synthetic-main-checkout")"

# --- ALLOW: the trigger filter -------------------------------------------------------------------------
# Three commands that name none of worktree / install / pytest. Without them, a filter that widened
# to every Bash call would cost a process per call and nothing here would notice.
assert_allow "git status"     "$(p "git status --porcelain" "/synthetic-main-checkout")"
assert_allow "a build"        "$(p "pnpm build" "/synthetic-main-checkout")"
assert_allow "a test run"     "$(p "pnpm test" "/synthetic-main-checkout")"

# --- ALLOW: a triggering verb that no sub-gate objects to ------------------------------------------------
assert_allow "listing worktrees" "$(p "git worktree list --porcelain" "/synthetic-main-checkout")"

# --- the dispatcher must forward, not paraphrase ----------------------------------------------------------
direct="$(p "pnpm install" "/synthetic-main-checkout" | bash "$(cd "$(dirname "$0")/.." && pwd)/block-pnpm-install-in-main.sh" 2>/dev/null)"
via="$(p "pnpm install" "/synthetic-main-checkout" | bash "$HOOK" 2>/dev/null)"
if [ -n "$direct" ] && [ "$direct" = "$via" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  FAILURES+=("FORWARDING: the dispatcher's output differs from the gate's own (direct=${#direct}B via=${#via}B)")
fi

# --- a missing sub-gate is skipped, not fatal ---------------------------------------------------------------
# The list names a gate this kit does not ship (block-stale-worktree-pytest.sh). A dispatcher that
# treated an absent entry as an error would take the whole mount down for everyone; a dispatcher that
# treated it as a denial would be worse. Measured here rather than assumed, because the arm above
# would stay green either way.
out="$(p "pytest tests/" "/synthetic-wt/r-widget" | bash "$HOOK" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  FAILURES+=("MISSING-SUBGATE: rc=$rc out='$(printf '%s' "$out" | head -c 120)'")
fi

summary

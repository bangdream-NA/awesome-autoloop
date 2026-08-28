#!/usr/bin/env bash
# block-pnpm-install-in-main — an install in the SHARED checkout rewrites the node_modules every
# other worktree is reading from, and an aborted one leaves it half-written. The gate denies the
# install verbs when the command or its cwd lands in the main repo, and yields to the worktree.
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/block-pnpm-install-in-main.sh

# --- portable activation context ---------------------------------------------------------------
AAL_PROJ=/tmp/aal-fx-block-pnpm-install-in-main
rm -rf "$AAL_PROJ"; mkdir -p "$AAL_PROJ/.claude"; : > "$AAL_PROJ/.claude/.autoloop"
export CLAUDE_PROJECT_DIR="$AAL_PROJ"
trap 'rm -rf "$AAL_PROJ"' EXIT

# Both paths are SYNTHETIC. The gate takes them as regexes from the environment, which is what
# makes it portable: no fixture needs to know where any real checkout lives.
export AAL_MAIN_REPO='/synthetic-main-checkout'
export AAL_WORKTREE_ROOT='/synthetic-wt/'
# -----------------------------------------------------------------------------------------------

p() { printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"cwd":"%s"}' "$1" "$2"; }

# --- DENY: an install verb whose context is the shared checkout ----------------------------------
assert_deny "pnpm install, cwd in main"  "$(p "pnpm install" "/synthetic-main-checkout/apps/web")"  'BLOCKED'
assert_deny "pnpm i, cwd in main"        "$(p "pnpm i" "/synthetic-main-checkout")"                 'BLOCKED'
assert_deny "pnpm add, cwd in main"      "$(p "pnpm add left-pad" "/synthetic-main-checkout")"      'BLOCKED'
assert_deny "pnpm update, cwd in main"   "$(p "pnpm update" "/synthetic-main-checkout")"            'BLOCKED'
assert_deny "the path in the COMMAND, cwd elsewhere" \
  "$(p "pnpm install --dir /synthetic-main-checkout" "/somewhere/else")" 'BLOCKED'

# --- ALLOW: the worktree, which is where installs belong -----------------------------------------
assert_allow "install inside a worktree" "$(p "pnpm install" "/synthetic-wt/r-widget")"
# Precedence, pinned deliberately: the worktree test runs FIRST and wins, so a command naming the
# main path while sitting in a worktree is allowed. Worth an arm because the opposite order would
# read identically on every other case in this file.
assert_allow "worktree cwd beats a main path in the command" \
  "$(p "pnpm install --dir /synthetic-main-checkout" "/synthetic-wt/r-widget")"

# --- ALLOW: not an install ------------------------------------------------------------------------
assert_allow "pnpm test in main"         "$(p "pnpm test" "/synthetic-main-checkout")"
assert_allow "pnpm run, not pnpm i"      "$(p "pnpm run install-deps" "/synthetic-main-checkout")"
assert_allow "a longer verb that merely starts with i" \
  "$(p "pnpm install-completion" "/synthetic-main-checkout")"

# --- ALLOW: the documented escape ------------------------------------------------------------------
assert_allow "the ALLOW_MAIN_INSTALL escape" \
  "$(p "pnpm install   # ALLOW_MAIN_INSTALL: bootstrapping the shared checkout on purpose" "/synthetic-main-checkout")"

# --- ALLOW: unconfigured means INERT, which is how an adopter meets this gate on day one ----------
# The gate exits early when AAL_MAIN_REPO is empty. Asserting it keeps a future "default to the
# repo root" change from silently denying installs for everyone who never set the variable.
AAL_MAIN_REPO=''
assert_allow "no AAL_MAIN_REPO configured" "$(p "pnpm install" "/synthetic-main-checkout")"
AAL_MAIN_REPO='/synthetic-main-checkout'

summary

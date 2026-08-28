#!/usr/bin/env bash
# require-runbook-update-after-state-change — a turn that changes persistent state on a box makes some
# paragraph of the runbook false, and a false runbook is worse than a missing one: a gap makes the
# next operator measure, a lie makes them act. The gate reads the turn's own transcript and blocks the
# stop when state changed and nothing under the runbook directory was written.
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/require-runbook-update-after-state-change.mjs

# --- portable activation context ---------------------------------------------------------------
AAL_TMP="$(mktemp -d)"
mkdir -p "$AAL_TMP/.claude"
: > "$AAL_TMP/.claude/.autoloop"
AAL_TMP_N="$(aal_native "$AAL_TMP")"
export CLAUDE_PROJECT_DIR="$AAL_TMP_N"
trap 'rm -rf "$AAL_TMP"' EXIT

# 🔴 The remote-host patterns are EMPTY until a project names its hosts, so the shipped default
# matches nothing — deliberately, rather than shipping somebody else's hostname. A fixture that left
# this unset would exercise a gate that is inert by construction and pass every arm.
export AAL_PROD_HOSTS='box-1.example.invalid'

# Each transcript is one turn: a user message, then the tool calls that turn made.
mkturn() { # $1 = out path, then triples of: toolName jsonInput
  node -e '
const fs = require("fs");
const rows = [JSON.stringify({ message: { role: "user", content: "do the thing" } })];
for (let i = 2; i < process.argv.length; i += 2) {
  rows.push(JSON.stringify({ message: { role: "assistant", content: [ { type: "tool_use", name: process.argv[i], input: JSON.parse(process.argv[i + 1]) } ] } }));
}
fs.writeFileSync(process.argv[1], rows.join("\n") + "\n");' -- "$@"
}
SSH_RESTART='{"command":"ssh deploy@box-1.example.invalid systemctl restart the-app"}'
SSH_READ='{"command":"ssh deploy@box-1.example.invalid systemctl status the-app"}'
LOCAL_RESTART='{"command":"systemctl restart the-app"}'

p() { node -e 'process.stdout.write(JSON.stringify({transcript_path:process.argv[1]}))' -- "$1"; }
# -----------------------------------------------------------------------------------------------

# --- FIRES: state changed, and no runbook was touched -----------------------------------------------
mkturn "$AAL_TMP/changed.jsonl" Bash "$SSH_RESTART"
assert_fires "a unit restarted over ssh" "$(p "$AAL_TMP_N/changed.jsonl")" 'received zero writes'
mkturn "$AAL_TMP/sudoers.jsonl" Bash '{"command":"ssh deploy@box-1.example.invalid sudo install -m 0440 /tmp/x /etc/sudoers.d/deploy"}'
assert_fires "a sudoers policy installed"  "$(p "$AAL_TMP_N/sudoers.jsonl")" 'received zero writes'
mkturn "$AAL_TMP/chown.jsonl" Bash '{"command":"ssh deploy@box-1.example.invalid sudo chown -R deploy /srv/app"}'
assert_fires "ownership changed"           "$(p "$AAL_TMP_N/chown.jsonl")" 'received zero writes'

# --- SILENT: the runbook was updated in the same turn --------------------------------------------------
mkturn "$AAL_TMP/updated.jsonl" Bash "$SSH_RESTART" Write '{"file_path":"/work/project/docs/runbooks/app-deploy.md","content":"x"}'
assert_quiet "a runbook write in the same turn" "$(p "$AAL_TMP_N/updated.jsonl")"

# --- SILENT: nothing changed --------------------------------------------------------------------------------
# A read over ssh is not a state change, and a restart on the LOCAL machine is not the box. Both need
# their own arm: widening either half would make every turn owe a runbook edit.
mkturn "$AAL_TMP/read.jsonl"  Bash "$SSH_READ"
assert_quiet "a read-only command"        "$(p "$AAL_TMP_N/read.jsonl")"
mkturn "$AAL_TMP/local.jsonl" Bash "$LOCAL_RESTART"
assert_quiet "the same verb, run locally" "$(p "$AAL_TMP_N/local.jsonl")"
mkturn "$AAL_TMP/none.jsonl"  Bash '{"command":"git status --porcelain"}'
assert_quiet "an ordinary command"        "$(p "$AAL_TMP_N/none.jsonl")"

# --- SILENT: nothing to read at all ---------------------------------------------------------------------------
assert_quiet "no transcript path"   "$(node -e 'process.stdout.write(JSON.stringify({}))')"
assert_quiet "a path that is not there" "$(p "$AAL_TMP_N/missing.jsonl")"

# --- the hosts seam is what arms this gate, and an unset one must leave it inert ---------------------------------
# Pinned deliberately: an adopter who has not named their hosts gets silence rather than a gate that
# fires on every `ssh` they run, and that is the state every installation starts in.
mkturn "$AAL_TMP/changed2.jsonl" Bash "$SSH_RESTART"
out="$(AAL_PROD_HOSTS='' p "$AAL_TMP_N/changed2.jsonl" | AAL_PROD_HOSTS='' node "$HOOK" 2>&1)"
if [ -z "$out" ] || [ "$out" = "{}" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("INERT-DEFAULT: with no hosts configured the gate still fired (got: $(printf '%s' "$out" | head -c 120))")
fi

summary

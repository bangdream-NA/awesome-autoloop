#!/usr/bin/env bash
# block-headless-browser — a browser launched headless cannot be looked at, so a "walk" that runs
# headless produces a verdict nobody saw. The gate denies a headless launch and yields to an
# explicit headed one.
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/block-headless-browser.sh

# --- portable activation context -------------------------------------------------------------
# Mounted gates self-skip unless the resolved project is autoloop-managed; without this every deny
# arm reads EXPECTED-DENY-BUT-ALLOWED with EMPTY output, which is what an inert gate looks like.
AAL_PROJ=/tmp/aal-fx-block-headless-browser
rm -rf "$AAL_PROJ"; mkdir -p "$AAL_PROJ/.claude"; : > "$AAL_PROJ/.claude/.autoloop"
export CLAUDE_PROJECT_DIR="$AAL_PROJ"
trap 'rm -rf "$AAL_PROJ"' EXIT
# ---------------------------------------------------------------------------------------------

bash_payload() { printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1"; }

# --- DENY: a launch that is explicitly headless ------------------------------------------------
assert_deny "explicit headless: true" \
  "$(bash_payload "node -e \\\"const b = await chromium.launch({ headless: true })\\\"")" \
  'headless'

assert_deny "playwright --headless flag" \
  "$(bash_payload "npx playwright test --headless")" \
  'headless'

# --- DENY: a bare launch with no headed marker — headless is the library default ----------------
assert_deny "bare .launch() with no headed marker" \
  "$(bash_payload "node -e \\\"const b = await chromium.launch({})\\\"")" \
  'headless'

# --- ALLOW: an explicitly headed launch, which is the shape a real walk uses --------------------
assert_allow "headless: false" \
  "$(bash_payload "node -e \\\"const b = await chromium.launch({ headless: false })\\\"")"

assert_allow "--headed" \
  "$(bash_payload "npx playwright test --headed")"

# --- ALLOW: the documented escape hatch, so the gate can be overridden in the open --------------
assert_allow "the HEADLESS-OK escape is honoured" \
  "$(bash_payload "node -e \\\"chromium.launch({ headless: true })\\\"  # HEADLESS-OK: CI smoke, no screenshot taken")"

# --- ALLOW: a command that merely MENTIONS the words is data, not a launch ----------------------
assert_allow "the phrase as data, not an invocation" \
  "$(bash_payload "grep -rn 'chromium.launch' docs/")"

assert_allow "unrelated command" "$(bash_payload "git status")"

summary

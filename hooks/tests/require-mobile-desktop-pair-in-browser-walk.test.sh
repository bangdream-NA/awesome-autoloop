#!/usr/bin/env bash
# require-mobile-desktop-pair-in-browser-walk — a narrow desktop window is not a phone: the user agent,
# the touch points and the pointer media queries are all unchanged, so every UA-sniffed response and
# every hover-only control behaves as it does on a desktop. The gate denies the resize shortcut, and
# denies an emulation call that carries only one of the two legs.
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/require-mobile-desktop-pair-in-browser-walk.mjs

# --- portable activation context ---------------------------------------------------------------
AAL_PROJ="$(mktemp -d)"
mkdir -p "$AAL_PROJ/.claude"
: > "$AAL_PROJ/.claude/.autoloop"
AAL_PROJ_N="$(aal_native "$AAL_PROJ")"
export CLAUDE_PROJECT_DIR="$AAL_PROJ_N"
trap 'rm -rf "$AAL_PROJ"' EXIT
# -----------------------------------------------------------------------------------------------

resize() { node -e 'process.stdout.write(JSON.stringify({tool_name:"mcp__playwright__browser_resize",tool_input:{width:Number(process.argv[1]),height:900}}))' -- "$1"; }
code()   { node -e 'process.stdout.write(JSON.stringify({tool_name:"mcp__playwright__browser_run_code_unsafe",tool_input:{code:process.argv[1]}}))' -- "$1"; }

MOBILE_LEG='await cdp.send("Emulation.setScrollbarsHidden", { hidden: true });
await cdp.send("Emulation.setDeviceMetricsOverride", { width: 390, height: 844, deviceScaleFactor: 3, mobile: true });'
DESKTOP_LEG='await cdp.send("Emulation.setDeviceMetricsOverride", { width: 1280, height: 900, deviceScaleFactor: 1, mobile: false });'

# --- DENY: resizing the window and calling it mobile -------------------------------------------------
assert_deny "a resize to phone width"  "$(resize 390)" 'NARROW DESKTOP'
assert_deny "…and to a smaller one"    "$(resize 375)" 'NARROW DESKTOP'

# --- ALLOW: a resize that is not pretending to be a phone ----------------------------------------------
assert_allow "a desktop resize"        "$(resize 1280)"
assert_allow "a wide resize"           "$(resize 1920)"

# --- DENY: an emulation call carrying only one leg ---------------------------------------------------------
assert_deny "mobile only"   "$(code "$MOBILE_LEG")"  'Desktop.. leg'
assert_deny "desktop only"  "$(code "$DESKTOP_LEG")" 'Mobile.. leg'
# 🔴 The scrollbar override is not a nicety. A desktop scrollbar occupies fifteen CSS pixels, so a leg
# that claims to be 390 wide is really rendering at 375 — and the difference shows up as clipped text
# and wrapped rows that exist nowhere but in the walk. Leaving it out MANUFACTURES defects rather than
# missing them, which is why its absence is a denial rather than a note.
assert_deny "both legs, no scrollbar override" \
  "$(code "await cdp.send(\"Emulation.setDeviceMetricsOverride\", { width: 390, height: 844, mobile: true });
$DESKTOP_LEG")" 'setScrollbarsHidden'

# --- ALLOW: both legs, with the override --------------------------------------------------------------------
assert_allow "the correct shape" "$(code "$MOBILE_LEG
$DESKTOP_LEG")"
# The widths can arrive as bare numerals when the call is parameterised, which is the shape a helper
# function produces. Without this, every walk written as a loop would be denied.
assert_allow "parameterised widths" \
  "$(code "await cdp.send(\"Emulation.setScrollbarsHidden\", { hidden: true });
const legs = [[390, 844, 3, true], [1280, 900, 1, false]];
for (const [w, h, s, m] of legs) await cdp.send(\"Emulation.setDeviceMetricsOverride\", { width: w, height: h, deviceScaleFactor: s, mobile: m });")"

# --- ALLOW: calls that emulate no device at all ----------------------------------------------------------------
# A purely desktop check — an OG image, a wide admin table — sets no device metrics, and the gate says
# nothing. This is the escape its own text names, and without an arm here tightening the predicate to
# "any browser code" would read green.
assert_allow "no device metrics"  "$(code 'const t = await page.title(); return t;')"
assert_allow "a screenshot only"  "$(code 'await page.screenshot({ path: "shot.png", fullPage: true });')"
assert_allow "an empty call"      "$(code '')"

# --- ALLOW: other tools ---------------------------------------------------------------------------------------------
assert_allow "a navigation" \
  "$(node -e 'process.stdout.write(JSON.stringify({tool_name:"mcp__playwright__browser_navigate",tool_input:{url:"https://example.invalid"}}))')"
assert_allow "a Bash command mentioning the width" \
  "$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:"echo width: 390"}}))')"

summary

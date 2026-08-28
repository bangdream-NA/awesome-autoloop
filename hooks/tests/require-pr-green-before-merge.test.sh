#!/usr/bin/env bash
# Fixtures for require-pr-green-before-merge.sh — gates `gh pr merge` on
# OPEN+not-draft+CI-green+APPROVED@HEAD-SHA. The gh/git-dependent deny paths need
# live PR context, so here we cover (a) ROUTING (non-merge → allow, no gh spawned)
# and (b) the two bug-prone PURE regexes that have actually mis-fired this project:
# the NEEDS-FIXES substring match and the HEAD-SHA marker.

source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/require-pr-green-before-merge.sh

# --- portable activation + repo context ------------------------------------------
# Two things every mounted gate needs before it will judge anything, and both are absent in a
# bare temp dir:
#   1. an AUTOLOOP-MANAGED project — lib/activation.sh accepts `.claude/.autoloop` |
#      `.claude/BACKLOG.md` | `.claude/code-reviews.md` | a marked `.claude/CLAUDE.md`. Without it
#      the gate exits 0 in silence and every deny arm reads EXPECTED-DENY-BUT-ALLOWED with EMPTY
#      output — the fixture then measures the guard instead of the gate.
#   2. a resolvable GIT REPOSITORY — the commit/merge gates refuse fail-closed otherwise, and that
#      refusal lands on the ALLOW arms as "the git repository cannot be resolved".
# The path is a literal so single-quoted JSON payloads below can name it; it is created fresh and
# removed on EXIT, and the resolution order prefers a payload `cd` hint that actually exists.
# ⚠️ Being a literal, it is also NOT unique per run: two copies of THIS fixture running at the
# same time share the directory and the first one's EXIT trap removes it under the second.
# run-all.sh is sequential and each CI job runs one OS, so that does not arise there — but do
# not parallelise a single fixture against itself.
AAL_PROJ=/tmp/aal-fx-require-pr-green-before-merge
rm -rf "$AAL_PROJ"
mkdir -p "$AAL_PROJ/.claude"
: > "$AAL_PROJ/.claude/.autoloop"
git -C "$AAL_PROJ" init -q 2>/dev/null || true
export CLAUDE_PROJECT_DIR="$AAL_PROJ"
trap 'rm -rf "$AAL_PROJ"' EXIT
# ---------------------------------------------------------------------------------


# --- ALLOW: non-merge commands exit before any gh call (line 18) ---
assert_allow "git status"        '{"command":"git status"}'
assert_allow "gh pr view"        '{"command":"gh pr view 5 --json state"}'
assert_allow "gh pr create"      '{"command":"gh pr create --title x"}'
assert_allow "git push (not merge)" '{"command":"git push origin feat/x:feat/x"}'
assert_allow "pnpm test"         '{"command":"pnpm -r test"}'

# --- Unit: NEEDS-FIXES verdict regex (line 102). Documents the substring footgun:
#     even a NEGATED mention matches → reviewers must avoid the literal 2-word string. ---
NF_RE='NEEDS[[:space:]]+(FIXES|REVISION)'
re_test() { local desc="$1" text="$2" expect="$3" re="$4";
  if echo "$text" | grep -qiE "$re"; then [ "$expect" = hit ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); FAILURES+=("UNEXPECTED-HIT: $desc"); };
  else [ "$expect" = miss ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); FAILURES+=("EXPECTED-HIT: $desc"); }; fi; }

re_test "verdict NEEDS FIXES"        "Verdict: NEEDS FIXES"            hit  "$NF_RE"
re_test "verdict NEEDS REVISION"     "Verdict: NEEDS  REVISION"       hit  "$NF_RE"
re_test "negated mention still hits" "This is NOT a NEEDS FIXES case"  hit  "$NF_RE"
re_test "clean APPROVED"             "Verdict: APPROVED"              miss "$NF_RE"
re_test "no fixes needed phrasing"   "no fixes needed; ship it"        miss "$NF_RE"

# --- Unit: HEAD-SHA marker regex (line 112) — accepts bold/backtick wrappers ---
SHA=8b855ac
HS_RE="(HEAD|@)[*\`[:space:]]*:?[*\`[:space:]]*${SHA}"
re_test "HEAD <sha>"        "HEAD $SHA"          hit  "$HS_RE"
re_test "HEAD: <sha>"       "HEAD: $SHA"         hit  "$HS_RE"
re_test "**HEAD**: <sha>"   "**HEAD**: $SHA"     hit  "$HS_RE"
re_test "@ <sha>"           "merged @ $SHA"      hit  "$HS_RE"
re_test "HEAD \`<sha>\`"    "HEAD \`$SHA\`"      hit  "$HS_RE"
re_test "bare 'off main <sha>' (no marker)" "off main $SHA" miss "$HS_RE"
re_test "different older sha"  "approved for abc1234" miss "$HS_RE"

# --- Unit: JSONL structured-verdict fast-path (mirrors the gate's node parser) ---
# Matches by pr + head_sha-prefix; last matching line wins; no match → '' (→ markdown fallback).
jsonl_verdict() { # <content> <pr> <head_short> -> verdict | ''
  echo "$1" | node -e "
    let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{let v='';
    for(const line of d.split('\n')){if(!line.trim())continue;try{const r=JSON.parse(line);
      if(String(r.pr)==='$2'&&typeof r.head_sha==='string'&&r.head_sha.indexOf('$3')===0){v=String(r.verdict||'');}}catch(_){}}
    console.log(v);});" 2>/dev/null
}
jv() { local desc="$1" content="$2" pr="$3" sha="$4" expect="$5"; local got; got=$(jsonl_verdict "$content" "$pr" "$sha");
  if [ "$got" = "$expect" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILURES+=("JSONL $desc: want '$expect' got '$got'"); fi; }

SAMPLE='{"pr":237,"head_sha":"c0c345fa11","verdict":"APPROVED","reviewer":"x"}
{"pr":99,"head_sha":"deadbeef00","verdict":"CHANGES_REQUIRED"}'
jv "APPROVED match by pr+sha-prefix" "$SAMPLE" 237 c0c345f APPROVED
jv "CHANGES_REQUIRED other pr"        "$SAMPLE" 99  deadbee CHANGES_REQUIRED
jv "wrong sha -> empty (fallback)"    "$SAMPLE" 237 ffffff  ""
jv "unknown pr -> empty (fallback)"   "$SAMPLE" 555 c0c345f ""
# last matching line wins (re-review supersedes)
SAMPLE2='{"pr":237,"head_sha":"abc1234","verdict":"CHANGES_REQUIRED"}
{"pr":237,"head_sha":"abc1234","verdict":"APPROVED"}'
jv "latest line wins (R2 APPROVED supersedes R1)" "$SAMPLE2" 237 abc1234 APPROVED

summary

#!/usr/bin/env bash
# sanitize-cjk-denylist.test.sh — Batch 1 (arch §A-10, §A-13). Locks the arms bin/sanitize-check.sh
# ships PUBLICLY, plus the accepted-line ledger's own staleness guard:
#   (1) CJK detection by explicit CODEPOINT RANGE. The cheap shell form [<start>-<end>] is
#       locale-dependent and also matches an em-dash, a middle dot and emoji — it read 1775 hits /
#       143 files where the true value is 26 / 10. A pure-ASCII control cannot tell the two apart:
#       it returns 0 under the broken predicate AND the correct one. The control that discriminates
#       sits in the GAP — a line that is non-ASCII and NON-CJK, which must return 0 — beside a
#       synthetic CJK line that must return 1. Both arms below, both printed.
#   (2) The domain-term denylist and the forbidden-pattern set, which are now LOADED from a wordlist
#       file rather than declared in the scanner. Each term is planted ALONE and asserted
#       individually. Planting all twelve and checking `rc != 0` passes when ONE of them matches,
#       which is how eleven silent holes ship green.
#   (3) The accepted-line ledger goes stale silently, because a hit-driven matcher only ever visits
#       lines that matched. STALE-a/STALE-b are its must-red / must-green pair, and STALE-c covers
#       the case the loader introduced: with no wordlist the ledger's denylist half is not checked
#       at all, because an entry whose ARM is not running has not gone stale.
#   (4) The report header must NAME THE TREE it describes. Three failure modes, each of which a
#       naive check passes: a non-git tree must still emit a legible NON-EMPTY token (an empty
#       field is indistinguishable from an emit that silently returned nothing), a DIRTY tree must
#       say so (rev-parse alone cannot detect one), and BOTH worlds must be asserted, because one
#       arm cannot tell "the fallback works" from "the fallback was never reached". HDR-a/b/c.
#   (5) The WORDLIST loader's three states (§A-13). WL-a/b/c are the contract; WL-d is the arm with
#       teeth — a tree with real findings and no wordlist must still FAIL, or the hosted lanes,
#       which check out no .claude/ and therefore always run wordlist-free, certify nothing.
#   (6) The FOURTH wordlist state, which is not one of the three: arrays that parse to EMPTY.
#       An empty pattern set does not match nothing — it matches EVERYTHING. `printf '%s\n'` with
#       zero arguments emits one byte, a bare newline, and an empty line in a `grep -f` pattern file
#       matches every line of every scanned file. EMPTY-a/b are the invariant, EMPTY-c is its
#       must-red on a mutated COPY, and EMPTY-d reproduces the mechanism raw so the arm survives a
#       redesign that changes the wordlist's shape.
#       🔴 EVERY ONE OF THEM ASSERTS THE MATCH COUNT, never the exit code: a universal matcher and a
#       working scanner both exit non-zero on a dirty tree, and only the count tells them apart.
#       ⚠️ This invariant and (5)'s pull in OPPOSITE directions. The natural fix for (5) — "treat an
#       absent wordlist as an empty set and keep scanning" — IS the universal matcher. Neither may
#       be satisfied by a change that breaks the other, so each carries its own arm here.
#
# 🔴 WHY THIS FIXTURE'S VOCABULARY IS SYNTHETIC, AND WHAT THAT BUYS.
#    The scanner's real patterns and real denylist terms live in the wordlist file, outside the
#    published tree. This fixture ships WITH the tree, so it must not spell them either — and it no
#    longer has to. It writes its OWN wordlist at run time, out of tokens that mean nothing to
#    anybody, and points the scanner at it. That tests the loader and the matching mechanism
#    carrying no vocabulary at all, which is strictly more coverage than moving the whole fixture
#    private would have been: the public kit keeps a tested gate. The arms that assert the REAL
#    twelve terms travel with the real wordlist, not with this file.
#
# 🔴 WHERE THE OTHER HALF OF THE SPLIT LIVES — F-8's PRIVATE ARM. Naming it is the point: a gate
#    whose private half has no home is a gate with one arm, and nothing in a public tree can ever
#    show that the half is missing.
#      path  : $(dirname "$AAL_SANITIZE_WORDLIST")/sanitize-wordlist.private.test.sh
#              i.e. .claude/ by default — `git check-ignore -v` returns `.gitignore:1:.claude/`,
#              must-zero control README.md returns rc=1. It is excluded by a rule that already
#              existed, so it cannot reach a tracked path by accident.
#      owner : the LEAD, in the same custody as the wordlist itself. It is never authored here.
#      scope : the same assertions as F-8's public arm below, run against the REAL twelve terms and
#              the REAL patterns instead of the synthetic ones — each term planted ALONE, each
#              caught INDIVIDUALLY.
#    ⚠️ run-all.sh globs "$HERE"/*.test.sh, so it does NOT discover that file — and that is the
#    design, not a gap. A hosted lane checks out no .claude/, has no wordlist, and must not fail on
#    an arm it structurally cannot run.
#
# 🔴 THE CJK PAYLOADS ARE STILL MATERIALISED AT RUN TIME AND NEVER SPELLED IN THIS FILE'S BYTES.
#    hooks/tests/** is inside the scanner's own SCAN_PATHS, so a committed CJK literal here would
#    make the shipped tree FAIL its own CJK arm — which is wordlist-free and therefore always on.
#    Hence CJK arrives as \uXXXX escapes through node. The halves-splitting the previous revision
#    needed for the denylist terms is GONE, because synthetic tokens match nothing in any wordlist.
#
# Isolation follows the precedent already shipped at sanitize-ci-username.test.sh: the scanner
# resolves $ROOT from `git rev-parse --show-toplevel || pwd`, so the scan tree is built under $HOME
# (never mktemp inside the worktree, or git resolves the REAL repo root and scans the real tree).
# $HOME is not a git repo on any supported runner, so rev-parse fails and $ROOT becomes the temp
# tree. Every case aborts LOUD if a run ever writes its report outside that tree.
#
# HERMETIC ON AAL_SANITIZE_WORDLIST, for the same reason this suite is hermetic on CI: a maintainer
# runs with one exported, a hosted lane runs with none, and an ambient value would silently decide
# which vocabulary every arm below measures. `scan` sets it explicitly or unsets it, never inherits.
#
# Toolchain: bash only, bash-3.2-safe. node is a hard requirement of the script under test, so the
# fixture uses it for payload bytes rather than depending on `printf '\uXXXX'` (bash 4.2+, absent on
# the macOS 3.2 lane).
# Run: bash hooks/tests/sanitize-cjk-denylist.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
SCANNER="$REPO_ROOT/bin/sanitize-check.sh"

PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }
halt(){ echo ""; echo "RESULT: $PASS passed, $FAIL failed (arms run: $((PASS+FAIL)))"; exit 1; }

command -v node >/dev/null 2>&1 || { echo "  [FAIL] node absent — this fixture cannot run"; exit 1; }

TREE="$(mktemp -d "$HOME/.aal-sancjk-XXXXXX")"
mkdir -p "$TREE/templates" "$TREE/.payloads" "$TREE/docs" "$TREE/.claude-plugin"
# The scanner is fail-closed on its resolved scan root (it refuses a tree without this repository's
# plugin manifest), so a fixture pointing it at a synthesized tree must mark that tree as a
# legitimate target. Inert to every arm: the project's own name is explicitly NOT a forbidden
# pattern, and the file carries no CJK and no denylist term. ROOT-a below asserts the unmarked case.
printf '{ "name": "awesome-autoloop" }\n' > "$TREE/.claude-plugin/plugin.json"
GTREE=""                     # the git-backed scan tree, built by the HDR arms; reaped by this trap
cleanup(){ rm -rf "$TREE"; if [ -n "$GTREE" ]; then rm -rf "$GTREE"; fi; }
trap cleanup EXIT

WORDLIST="$TREE/.payloads/wordlist.json"          # synthetic; NOT under any SCAN_PATHS entry
WORDLIST_BAD="$TREE/.payloads/wordlist-malformed.json"
WORDLIST_MISSING="$TREE/.payloads/wordlist-does-not-exist.json"
WORDLIST_EMPTY="$TREE/.payloads/wordlist-empty.json"

# ---- payload materialisation (run time, never a committed literal) --------------------------------
node - "$TREE" <<'NODEJS'
const fs = require('node:fs');
const T = process.argv[2];
const P = T + '/.payloads/';            // NOT under any SCAN_PATHS entry, so payloads are inert here

// The synthetic vocabulary. Twelve terms, same cardinality as the real floor so the "no term
// shadows another" arm keeps its shape; none is a substring of any other, so a plant of one is
// attributable to exactly one. Two patterns, both carrying a regex metacharacter, because the
// loader is a NEW serialisation boundary for them: the bracketed one must behave as an ERE, and
// the escaped dot must keep its backslash across the JSON round-trip.
const TERMS = [];
for (let i = 1; i <= 12; i++) TERMS.push('zqxdeny' + String(i).padStart(2, '0'));
const PATS = ['zqxleak[0-9]', 'zqx\\.dot'];
fs.writeFileSync(P + 'wordlist.json', JSON.stringify({ patterns: PATS, deny: TERMS }, null, 2) + '\n');
fs.writeFileSync(P + 'wordlist-malformed.json', '{');     // the single byte A-13 names
// The FOURTH state. It PARSES and it validates — every entry in an empty array is trivially a
// non-empty single-line string — so nothing upstream of the matcher can reject it.
fs.writeFileSync(P + 'wordlist-empty.json', JSON.stringify({ patterns: [], deny: [] }, null, 2) + '\n');
fs.writeFileSync(P + 'terms.txt', TERMS.join('\n') + '\n');
TERMS.forEach((t, i) => fs.writeFileSync(P + 'deny' + i + '.txt', 'a line that mentions ' + t + ' once\n'));
fs.writeFileSync(P + 'deny-all.txt', TERMS.map((t) => 'line for ' + t).join('\n') + '\n');

// Pattern plants. The bracketed pattern matches this line only as an ERE — as a fixed string it
// does not match at all, so PAT-a dies if the loaded strings are ever treated as literals.
// The escape pair is next: the near miss must NOT match, or the backslash was lost in transit.
fs.writeFileSync(P + 'static.txt', 'a project literal zqxleak7 leaked here\n');
fs.writeFileSync(P + 'escape-hit.txt', 'the escaped pattern zqx.dot appears here\n');
fs.writeFileSync(P + 'escape-miss.txt', 'a near miss zqxXdot appears here\n');

// CJK payload and the control that sits in the gap between "non-ASCII" and "CJK".
const CJK_LINE  = 'prose line ' + '\u4e2d\u6587\u6d4b\u8bd5' + ' here';
const CJK_ID    = 'maintainer handle ' + '\u96ea\u5c71' + ' inline';   // synthetic, not a real name
const NON_CJK   = 'punctuation \u2014 \u00b7 \u00d7 \u00b0 \u00e9 \u00bd \u2192 only';
fs.writeFileSync(P + 'cjk.txt', CJK_LINE + '\n');
fs.writeFileSync(P + 'cjkid.txt', CJK_ID + '\n');
fs.writeFileSync(P + 'nonascii.txt', NON_CJK + '\n');
fs.writeFileSync(P + 'benign.txt', 'plain ascii prose, nothing to see\n');
// A MULTI-LINE benign subject, for the empty-set arms alone. Their assertion is a COUNT, and a
// one-line plant cannot carry one: "1 finding" and "every line is a finding" would be the same
// number. Seven lines makes the universal-matcher reading unmistakable, and the fixture DERIVES the
// expected count from the tree rather than writing it down.
fs.writeFileSync(P + 'multi.txt',
  Array.from({ length: 7 }, (_, i) => 'benign subject line ' + (i + 1)).join('\n') + '\n');

// Two variants of a file at a path the shipped accepted-ledger keys on, to exercise the staleness
// guard. Line 44 carries an accepted denylist term; line 69 carries accepted CJK in the FRESH
// variant and plain ascii in the STALE one — the only delta between them.
const mk = (l69) => { const a = []; for (let i = 1; i <= 70; i++)
  a.push(i === 44 ? 'row about a ' + TERMS[2] : i === 69 ? l69 : 'filler line ' + i); return a.join('\n') + '\n'; };
fs.writeFileSync(P + 'op-fresh.md', mk('legacy ' + '\u72b6\u6001' + ': literal'));
fs.writeFileSync(P + 'op-stale.md', mk('legacy status: literal'));
NODEJS
[ -f "$TREE/.payloads/cjk.txt" ] || { echo "  [FAIL] payload materialisation produced nothing"; exit 1; }
[ -f "$WORDLIST" ] || { echo "  [FAIL] the synthetic wordlist was not written"; exit 1; }

# ---- scanner driver ------------------------------------------------------------------------------
# SCAN_WL selects the wordlist state for the next run: a path, or the empty string for "no wordlist".
# Always scrubs CI/USER/USERNAME (run-all.sh also executes on the hosted CI leg where CI=true is
# ambient, and the username augment would otherwise vary the pattern set between runners) and always
# scrubs or sets AAL_SANITIZE_WORDLIST, never inherits it.
SCAN_WL="$WORDLIST"
scan() {
  if [ -n "$SCAN_WL" ]; then
    ( cd "$TREE" && env -u CI -u USER -u USERNAME AAL_SANITIZE_WORDLIST="$SCAN_WL" \
        bash "$SCANNER" >/dev/null 2>&1 ); SCAN_RC=$?
  else
    ( cd "$TREE" && env -u CI -u USER -u USERNAME -u AAL_SANITIZE_WORDLIST \
        bash "$SCANNER" >/dev/null 2>&1 ); SCAN_RC=$?
  fi
  if [ -f "$TREE/sanitization-report.txt" ]; then
    SCAN_ISO=YES
    SCAN_CLASSES=$(sed -n 's/^Findings by class: //p' "$TREE/sanitization-report.txt")
    SCAN_WLHDR=$(sed -n 's/^wordlist: //p'            "$TREE/sanitization-report.txt")
    SCAN_RESULT=$(sed -n 's/^RESULT: //p'             "$TREE/sanitization-report.txt")
    SCAN_PATS=$(sed -n 's/^Patterns checked: //p'     "$TREE/sanitization-report.txt")
  else SCAN_ISO=LEAK; SCAN_CLASSES=""; SCAN_WLHDR=""; SCAN_RESULT=""; SCAN_PATS=""; fi
  rm -f "$TREE/sanitization-report.txt"
}
reset_tree() { rm -f "$TREE/templates"/* "$TREE/docs"/*; }
plant()      { cp "$TREE/.payloads/$1" "$TREE/templates/$2"; }

# expect <label> <rc: 0|1> <exact class breakdown> — asserts the exit code AND per-arm attribution,
# so a RED is provably the NEW arm rather than a pre-existing static pattern firing.
expect() {
  l="$1"; want_rc="$2"; want_cls="$3"; scan
  [ "$SCAN_ISO" = YES ] || { bad "$l — ISOLATION LEAK: scanner escaped the temp tree"; halt; }
  if [ "$SCAN_RC" != "$want_rc" ]; then bad "$l — expected rc=$want_rc, got rc=$SCAN_RC [$SCAN_CLASSES]"
  elif [ "$SCAN_CLASSES" != "$want_cls" ]; then bad "$l — classes: expected [$want_cls], got [$SCAN_CLASSES]"
  else ok "$l"; fi
}

echo "== BASELINE: the synthesized tree is clean, so every FAIL below is attributable to its plant =="
SCAN_WL="$WORDLIST"
reset_tree; plant benign.txt note.txt
expect "BASE tree with benign ascii only -> PASS 0, every class 0" 0 "patterns 0 · cjk 0 · denylist 0 · stale-accepted 0"

echo "== F-7: the CJK predicate DISCRIMINATES (a pure-ASCII control would pass under both forms) =="
reset_tree; plant nonascii.txt punct.txt
expect "F-7a CONTROL non-ASCII, NON-CJK (em-dash, middle dot, multiplication sign) -> 0 cjk findings" 0 "patterns 0 · cjk 0 · denylist 0 · stale-accepted 0"
reset_tree; plant cjk.txt prose.txt
expect "F-7b synthetic CJK line -> exactly 1 cjk finding, and patterns 0 (the RED is non-vacuous)" 1 "patterns 0 · cjk 1 · denylist 0 · stale-accepted 0"
# The CJK arm carries no vocabulary, so it is the arm a public user actually gets. Asserting it with
# the wordlist REMOVED is the only way to show that, and it is what the hosted lanes run.
SCAN_WL=""
reset_tree; plant cjk.txt prose.txt
expect "F-7c same CJK line with NO wordlist -> still cjk 1 (the arm CI certifies is wordlist-free)" 1 "patterns 0 · cjk 1 · denylist 0 · stale-accepted 0"
SCAN_WL="$WORDLIST"

echo "== IDENTITY: a CJK handle is caught by the RANGE, never by a wordlist entry =="
reset_tree; plant cjkid.txt handle.txt
expect "IDENT synthetic CJK handle -> cjk 1, patterns 0 (no identity literal is ever committed)" 1 "patterns 0 · cjk 1 · denylist 0 · stale-accepted 0"

echo "== F-8 (public arm): each of the 12 SYNTHETIC terms, planted ALONE, caught INDIVIDUALLY =="
i=0
while [ "$i" -lt 12 ]; do
  reset_tree; plant "deny$i.txt" "d.txt"
  term=$(sed -n "$((i+1))p" "$TREE/.payloads/terms.txt")
  expect "F-8[$i] term '$term' alone -> denylist 1, cjk 0, patterns 0" 1 "patterns 0 · cjk 0 · denylist 1 · stale-accepted 0"
  i=$((i+1))
done
reset_tree; plant deny-all.txt all.txt
expect "F-8[all] all 12 planted together -> denylist 12 (no term shadows another)" 1 "patterns 0 · cjk 0 · denylist 12 · stale-accepted 0"
# The discriminating control for all thirteen arms above: the SAME plant with the wordlist removed
# must catch NOTHING. Without it, every arm above is satisfied by any mechanism that happens to be
# matching — including one that ignores the wordlist entirely and matches something ambient.
SCAN_WL=""
reset_tree; plant deny-all.txt all.txt
expect "F-8[none] CONTROL the same 12 with NO wordlist -> denylist 0 (the 13 arms measure the LOADER)" 0 "patterns 0 · cjk 0 · denylist 0 · stale-accepted 0"
SCAN_WL="$WORDLIST"

echo "== PATTERNS: the loaded set is applied as an ERE, and its escapes survive the JSON round-trip =="
reset_tree; plant static.txt leak.txt
expect "PAT-a bracketed pattern -> patterns 1 (matches as an ERE, would not as a fixed string)" 1 "patterns 1 · cjk 0 · denylist 0 · stale-accepted 0"
reset_tree; plant escape-hit.txt hit.txt
expect "PAT-b the escaped-dot pattern on its literal -> patterns 1 (must-hit)" 1 "patterns 1 · cjk 0 · denylist 0 · stale-accepted 0"
reset_tree; plant escape-miss.txt miss.txt
expect "PAT-c CONTROL the near miss -> patterns 0 (the backslash survived; an unescaped dot would hit)" 0 "patterns 0 · cjk 0 · denylist 0 · stale-accepted 0"
SCAN_WL=""
reset_tree; plant static.txt leak.txt
expect "PAT-d CONTROL the same plant with NO wordlist -> patterns 0 (the arm is the wordlist's)" 0 "patterns 0 · cjk 0 · denylist 0 · stale-accepted 0"
SCAN_WL="$WORDLIST"

echo "== STALE: the accepted ledger is walked as a LIST, so an entry that stops matching goes RED =="
reset_tree; cp "$TREE/.payloads/op-stale.md" "$TREE/docs/OPERATING.md"
expect "STALE-a accepted line no longer matches -> stale-accepted 1 (the must-red for the ledger)" 1 "patterns 0 · cjk 0 · denylist 0 · stale-accepted 1"
reset_tree; cp "$TREE/.payloads/op-fresh.md" "$TREE/docs/OPERATING.md"
expect "STALE-b same file, accepted line restored -> stale-accepted 0 (must-green control)" 0 "patterns 0 · cjk 0 · denylist 0 · stale-accepted 0"
# An entry whose ARM is not running has not gone stale. Without this gate the wordlist-free
# configuration reports all ten ACCEPT_DENY entries as findings on a tree that is perfectly clean,
# and "10 findings" would be the normal reading on every hosted lane.
SCAN_WL=""
reset_tree; cp "$TREE/.payloads/op-fresh.md" "$TREE/docs/OPERATING.md"
expect "STALE-c same file with NO wordlist -> stale-accepted 0 (an unrun arm's entries are not stale)" 0 "patterns 0 · cjk 0 · denylist 0 · stale-accepted 0"
SCAN_WL="$WORDLIST"

echo "== ROOT: the scanner refuses a tree that is not this repository, AND writes nothing there =="
# Two assertions, not one. `rc != 0` alone cannot distinguish "refused before touching the disk" from
# "scanned it, found hits, and left a full verbatim report behind" — and it is the second half that
# made this worth fixing. NOROOT is deliberately built WITHOUT the plugin manifest and WITH a
# SCAN_PATHS directory, because a home directory that carried bin/ and templates/ is exactly what the
# scanner walked when this fired for real.
NOROOT="$(mktemp -d "$HOME/.aal-sanroot-XXXXXX")"; mkdir -p "$NOROOT/templates"
printf 'plain ascii prose, nothing to see\n' > "$NOROOT/templates/x.txt"
( cd "$NOROOT" && env -u CI -u USER -u USERNAME -u AAL_SANITIZE_WORDLIST bash "$SCANNER" >/dev/null 2>&1 ); ROOT_RC=$?
if [ "$ROOT_RC" = 2 ]; then ok "ROOT-a unmarked tree -> refuses fail-closed (rc=2)"
else bad "ROOT-a expected rc=2 (refuse), got rc=$ROOT_RC"; fi
if [ -f "$NOROOT/sanitization-report.txt" ]; then bad "ROOT-a wrote a report into the tree it refused to scan"
else ok "ROOT-a wrote NO report into the refused tree"; fi
rm -rf "$NOROOT"
reset_tree; plant benign.txt note.txt
expect "ROOT-b same shape WITH the manifest -> scans normally (must-green control)" 0 "patterns 0 · cjk 0 · denylist 0 · stale-accepted 0"

echo "== WL (§A-13): the wordlist loader's three states, and the one with teeth =="
# WL-a/b are also F-21: the header is the ONLY thing that tells a signer which vocabulary produced
# the report they are signing. Before this line existed that failure was not detectable at all.
reset_tree; plant benign.txt note.txt
SCAN_WL="$WORDLIST"; scan
if [ "$SCAN_WLHDR" = "$WORDLIST (patterns 2, deny 12)" ]; then
  ok "WL-a configured -> header names the resolved path AND both counts [$SCAN_WLHDR]"
else bad "WL-a expected [$WORDLIST (patterns 2, deny 12)], header carried [$SCAN_WLHDR]"; fi
if [ "$SCAN_RESULT" = "PASS (0 findings)" ]; then ok "WL-a configured, clean tree -> RESULT: $SCAN_RESULT"
else bad "WL-a expected [PASS (0 findings)], got [$SCAN_RESULT]"; fi

# ABSENT. Asserted through an explicitly SET but nonexistent path, not through an unset variable:
# those are two different code paths and only this one proves the default is not silently winning.
reset_tree; plant benign.txt note.txt
SCAN_WL="$WORDLIST_MISSING"; scan
if [ "$SCAN_WLHDR" = "not configured" ]; then ok "WL-b absent -> header reads the literal [wordlist: $SCAN_WLHDR]"
else bad "WL-b expected header [not configured], carried [$SCAN_WLHDR]"; fi
if [ "$SCAN_RESULT" = "PARTIAL PASS (0 findings; 2 arms not configured)" ]; then
  ok "WL-b absent, clean tree -> RESULT: $SCAN_RESULT"
else bad "WL-b expected [PARTIAL PASS (0 findings; 2 arms not configured)], got [$SCAN_RESULT]"; fi
if [ "$SCAN_RC" = 0 ]; then ok "WL-b absent -> exit 0 (a public user with no wordlist gets a green lane)"
else bad "WL-b expected rc=0, got rc=$SCAN_RC"; fi
# The count is COMPUTED, not written down, and the two readings below are what makes that visible.
# `scan` scrubs USER/USERNAME, so nothing is left to count and the honest answer is 0 -- which is
# also what a hosted lane reads, because CI=true suppresses the augment there. A hardcoded "1"
# would print a pattern count of one on a lane carrying none.
if [ "$SCAN_PATS" = "0 (wordlist not configured, 0 terms)" ]; then
  ok "WL-b absent, no OS username -> the summary says so too [Patterns checked: $SCAN_PATS]"
else bad "WL-b expected [0 (wordlist not configured, 0 terms)], got [$SCAN_PATS]"; fi
# The two result lines must not be byte-identical, or the instrument fails silently by passing.
if [ "$SCAN_RESULT" != "PASS (0 findings)" ]; then
  ok "WL-b the absent reading is NOT byte-identical to a full pass"
else bad "WL-b absent state produced a full-pass result line"; fi

# The other half of that pair: the wordlist-free run still carries the runtime username augment, so
# with a username present the count is 1. Run directly rather than through `scan`, which scrubs it.
reset_tree; plant benign.txt note.txt
rm -f "$TREE/sanitization-report.txt"
( cd "$TREE" && env -u CI -u USER USERNAME=zqxwluser AAL_SANITIZE_WORDLIST="$WORDLIST_MISSING" \
    bash "$SCANNER" >/dev/null 2>&1 ); WLAUG_RC=$?
WLAUG_PATS=$(sed -n 's/^Patterns checked: //p' "$TREE/sanitization-report.txt" 2>/dev/null)
rm -f "$TREE/sanitization-report.txt"
if [ "$WLAUG_PATS" = "1 (wordlist not configured, 0 terms)" ] && [ "$WLAUG_RC" = 0 ]; then
  ok "WL-e absent + an OS username -> [Patterns checked: $WLAUG_PATS], rc=$WLAUG_RC (the augment survives)"
else bad "WL-e expected [1 (wordlist not configured, 0 terms)] rc=0, got [$WLAUG_PATS] rc=$WLAUG_RC"; fi

# 🔴 THE ARM WITH TEETH. Findings still FAIL with no wordlist. The hosted lanes always run this
# configuration, so if absence alone forced exit 0 they would certify nothing at all — and every
# expect_fail arm in sanitize-ci-username.test.sh would pass by blindness rather than by working.
reset_tree; plant cjk.txt prose.txt
SCAN_WL="$WORDLIST_MISSING"; scan
if [ "$SCAN_RC" = 1 ] && [ "$SCAN_RESULT" = "FAIL (1 findings; 2 arms not configured)" ]; then
  ok "WL-d absent + a real CJK finding -> rc=1 and RESULT: $SCAN_RESULT"
else bad "WL-d expected rc=1 and [FAIL (1 findings; 2 arms not configured)], got rc=$SCAN_RC [$SCAN_RESULT]"; fi

# MALFORMED. Two assertions, for the same reason ROOT-a has two: an exit code alone cannot tell
# "refused before writing" from "wrote a report and then complained".
reset_tree; plant benign.txt note.txt
rm -f "$TREE/sanitization-report.txt"
( cd "$TREE" && env -u CI -u USER -u USERNAME AAL_SANITIZE_WORDLIST="$WORDLIST_BAD" \
    bash "$SCANNER" >/dev/null 2>&1 ); WLBAD_RC=$?
if [ "$WLBAD_RC" = 2 ]; then ok "WL-c malformed wordlist (a single opening brace) -> FATAL rc=2"
else bad "WL-c expected rc=2, got rc=$WLBAD_RC"; fi
if [ -f "$TREE/sanitization-report.txt" ]; then bad "WL-c wrote a report despite refusing to scan"
else ok "WL-c wrote NO report (a half-parsed wordlist must not produce one)"; fi
rm -f "$TREE/sanitization-report.txt"
SCAN_WL="$WORDLIST"

echo "== EMPTY (§A-13 invariant (a)): a wordlist that parses to an EMPTY SET is INERT, not universal =="
# The state the three-state table does not name. It parses, it validates, and it reaches the matcher
# as zero patterns -- at which point `printf '%s\n'` over an empty array writes ONE BYTE, a bare
# newline, and an empty line in a `grep -f` pattern file matches EVERY line of EVERY scanned file.
#
# 🔴 THE ASSERTION IS THE COUNT, NEVER THE EXIT CODE. A universal matcher and a working scanner both
# exit non-zero on a dirty tree; the number is the only thing that separates them. And the expected
# number is DERIVED from the tree rather than written down, so a later change to the fixture's own
# plants cannot leave a stale constant behind that reads as a passing arm.
reset_tree; plant multi.txt subject.txt
EMPTY_ALL=$(awk 'END{print NR}' "$TREE/.claude-plugin/plugin.json" "$TREE/templates"/*)
echo "  (derived) lines a universal matcher would report on this tree: $EMPTY_ALL"
SCAN_WL="$WORDLIST_EMPTY"
expect "EMPTY-a empty arrays over a $EMPTY_ALL-line tree -> patterns 0 (INERT, not universal)" 0 "patterns 0 · cjk 0 · denylist 0 · stale-accepted 0"

# The deny half of the same invariant. Its must-GREEN control is F-8[all] above, which reports 12 on
# this identical plant with the synthetic wordlist resolved -- so a 0 here is the empty ARRAY, not a
# denylist arm that stopped running.
reset_tree; plant deny-all.txt all.txt
expect "EMPTY-b empty deny array over the same 12-term plant -> denylist 0 (F-8[all] reads 12)" 0 "patterns 0 · cjk 0 · denylist 0 · stale-accepted 0"
SCAN_WL="$WORDLIST"

# MUST-RED, on a COPY so no shipped byte is ever mutated: defeat the count guard the scanner puts in
# front of the matcher and the same empty wordlist must report EVERY line. Without this arm EMPTY-a
# is satisfied by a scanner that stopped scanning -- "0 findings because the set is inert" and
# "0 findings because nothing runs" are the same reading.
reset_tree; plant multi.txt subject.txt
EMPTY_MUT="$TREE/.payloads/scanner-unguarded.copy"
sed 's/^if \[ "\$PATTERN_COUNT" -gt 0 \]; then$/if [ 1 = 1 ]; then/' "$SCANNER" > "$EMPTY_MUT"
# The mutation self-proves before it is trusted: the anchor matched EXACTLY once (a zero-hit sed is
# silent and leaves a copy identical to the original, which would then pass EMPTY-c by being right
# for the wrong reason), and the result still parses.
EMPTY_MUT_ANCHOR=$(grep -c '^if \[ 1 = 1 \]; then$' "$EMPTY_MUT")
bash -n "$EMPTY_MUT" 2>/dev/null; EMPTY_MUT_SYNTAX=$?
if [ "$EMPTY_MUT_ANCHOR" = 1 ] && [ "$EMPTY_MUT_SYNTAX" = 0 ]; then
  ok "EMPTY-c setup mutation applied exactly once and still parses (anchor=$EMPTY_MUT_ANCHOR, bash -n rc=$EMPTY_MUT_SYNTAX)"
else
  bad "EMPTY-c setup expected anchor=1 and bash -n rc=0, got anchor=$EMPTY_MUT_ANCHOR rc=$EMPTY_MUT_SYNTAX"; halt
fi
rm -f "$TREE/sanitization-report.txt"
( cd "$TREE" && env -u CI -u USER -u USERNAME AAL_SANITIZE_WORDLIST="$WORDLIST_EMPTY" \
    bash "$EMPTY_MUT" >/dev/null 2>&1 ); EMPTY_MUT_RC=$?
EMPTY_MUT_CLS=$(sed -n 's/^Findings by class: //p' "$TREE/sanitization-report.txt" 2>/dev/null)
rm -f "$TREE/sanitization-report.txt"
if [ "$EMPTY_MUT_CLS" = "patterns $EMPTY_ALL · cjk 0 · denylist 0 · stale-accepted 0" ]; then
  ok "EMPTY-c MUST-RED guard defeated -> patterns $EMPTY_ALL, i.e. every scanned line (rc=$EMPTY_MUT_RC)"
else
  bad "EMPTY-c MUST-RED expected [patterns $EMPTY_ALL · ...], got [$EMPTY_MUT_CLS] rc=$EMPTY_MUT_RC"
fi
# ...and the SAME mutated copy with a REAL wordlist reports 0, which is what makes the arm above a
# statement about the empty set rather than about a copy that is simply broken.
rm -f "$TREE/sanitization-report.txt"
( cd "$TREE" && env -u CI -u USER -u USERNAME AAL_SANITIZE_WORDLIST="$WORDLIST" \
    bash "$EMPTY_MUT" >/dev/null 2>&1 ); EMPTY_MUT2_RC=$?
EMPTY_MUT2_CLS=$(sed -n 's/^Findings by class: //p' "$TREE/sanitization-report.txt" 2>/dev/null)
rm -f "$TREE/sanitization-report.txt"; rm -f "$EMPTY_MUT"
if [ "$EMPTY_MUT2_CLS" = "patterns 0 · cjk 0 · denylist 0 · stale-accepted 0" ] && [ "$EMPTY_MUT2_RC" = 0 ]; then
  ok "EMPTY-c CONTROL the same mutated copy + a REAL wordlist -> patterns 0 rc=0 (not a general break)"
else
  bad "EMPTY-c CONTROL expected [patterns 0 · ...] rc=0, got [$EMPTY_MUT2_CLS] rc=$EMPTY_MUT2_RC"
fi

# EMPTY-d: the mechanism itself, one layer below the scanner. This arm is DESIGN-INDEPENDENT -- it
# holds for any implementation in which the pattern set can become emptiable, including one written
# by somebody who never read A-13 -- so it is asserted on `printf` and `grep` directly rather than
# through the scanner that happens to guard it today.
EMPTY_PF="$TREE/.payloads/patfile-empty"
REAL_PF="$TREE/.payloads/patfile-real"
EMPTY_ARR=()
printf '%s\n' ${EMPTY_ARR[@]+"${EMPTY_ARR[@]}"} > "$EMPTY_PF"     # the scanner's own line, verbatim
printf '%s\n' 'zqxleak[0-9]' 'zqxdeny01' > "$REAL_PF"
EMPTY_PF_BYTES=$(wc -c < "$EMPTY_PF" | tr -d ' ')
EMPTY_SUBJ_N=$(awk 'END{print NR}' "$TREE/.payloads/multi.txt")
EMPTY_D_HITS=$(grep -c -f "$EMPTY_PF" "$TREE/.payloads/multi.txt"); EMPTY_D_RC=$?
REAL_D_HITS=$(grep -c -f "$REAL_PF" "$TREE/.payloads/multi.txt");  REAL_D_RC=$?
rm -f "$EMPTY_PF" "$REAL_PF"
if [ "$EMPTY_PF_BYTES" = 1 ] && [ "$EMPTY_D_HITS" = "$EMPTY_SUBJ_N" ] && [ "$EMPTY_D_RC" = 0 ]; then
  ok "EMPTY-d printf over an empty array -> $EMPTY_PF_BYTES byte, and grep -f matches $EMPTY_D_HITS of $EMPTY_SUBJ_N lines (rc=$EMPTY_D_RC)"
else
  bad "EMPTY-d expected 1 byte and $EMPTY_SUBJ_N of $EMPTY_SUBJ_N matched at rc=0, got ${EMPTY_PF_BYTES}B $EMPTY_D_HITS hits rc=$EMPTY_D_RC"
fi
if [ "$REAL_D_HITS" = 0 ] && [ "$REAL_D_RC" = 1 ]; then
  ok "EMPTY-d CONTROL two real patterns over the same subject -> $REAL_D_HITS hits, rc=$REAL_D_RC"
else
  bad "EMPTY-d CONTROL expected 0 hits at rc=1, got $REAL_D_HITS hits rc=$REAL_D_RC"
fi

echo "== HDR: the report header NAMES THE TREE it describes -- both worlds, clean and dirty =="
# AC1's header checkbox. Every reading is PRINTED, because the three failure modes are exactly the
# ones a naive check waves through, and because after the 2026-08-21 ruling this header is the
# signer's ONLY tie between a report and the commit it describes.
hdr_tree() {   # the token after the timestamp in the report header, or the empty string
  sed -n "s/^.*sanitization report (\(.*\))[[:space:]]*\$/\1/p" "$1" | sed "s/^.*, //"
}
run_in()  { ( cd "$1" && env -u CI -u USER -u USERNAME -u AAL_SANITIZE_WORDLIST \
                bash "$SCANNER" >/dev/null 2>&1 ); }

GTREE="$(mktemp -d "$HOME/.aal-sanhdr-XXXXXX")"
mkdir -p "$GTREE/.claude-plugin" "$GTREE/templates"
printf '{ "name": "awesome-autoloop" }\n' > "$GTREE/.claude-plugin/plugin.json"
printf 'plain ascii prose, nothing to see\n' > "$GTREE/templates/note.txt"
# The scanner writes its report INTO the tree it scans, so without this the run's own artifact
# would dirty the tree and the CLEAN half of HDR-a could never be observed. The shipped repository
# ignores the same file for the same reason.
printf 'sanitization-report.txt\n' > "$GTREE/.gitignore"
git -C "$GTREE" init -q >/dev/null 2>&1
git -C "$GTREE" add -A >/dev/null 2>&1
git -C "$GTREE" -c user.name=aal-fixture -c user.email=aal-fixture@example.invalid \
  -c commit.gpgsign=false commit -q -m "fixture tree" >/dev/null 2>&1
GSHA="$(git -C "$GTREE" rev-parse HEAD 2>/dev/null)"
# Both setup predicates FAIL rather than skip. A skipped arm and a passing arm read identically in
# the tally, so an arm that cannot run must not be silently absent from the denominator.
if [ -z "$GSHA" ]; then bad "HDR setup -- could not build a git-backed scan tree (no sha)"; halt; fi
GSTATUS="$(git -C "$GTREE" status --porcelain 2>/dev/null)"
if [ -n "$GSTATUS" ]; then bad "HDR setup -- the fixture git tree is not clean: [$GSTATUS]"; halt; fi

run_in "$GTREE"; HDR_A="$(hdr_tree "$GTREE/sanitization-report.txt")"
rm -f "$GTREE/sanitization-report.txt"
if [ "$HDR_A" = "$GSHA" ]; then ok "HDR-a git tree, CLEAN -> header names the commit [$HDR_A]"
else bad "HDR-a git tree, CLEAN -> expected [$GSHA], header carried [$HDR_A]"; fi

# A tracked file, edited and not committed: rev-parse still returns the same sha, so without the
# marker this report and HDR-a's would be byte-identical while describing different bytes.
printf 'a second benign ascii line\n' >> "$GTREE/templates/note.txt"
run_in "$GTREE"; HDR_B="$(hdr_tree "$GTREE/sanitization-report.txt")"
rm -f "$GTREE/sanitization-report.txt"
if [ "$HDR_B" = "$GSHA-dirty" ]; then ok "HDR-b same tree, uncommitted edit -> header says so [$HDR_B]"
else bad "HDR-b expected [$GSHA-dirty], header carried [$HDR_B]"; fi

# The other world. $HOME is not a git worktree on any supported runner (the ROOT arms above already
# lean on that), so this exercises the fallback branch rather than merely re-running the first one.
reset_tree; plant benign.txt note.txt
run_in "$TREE"; HDR_C="$(hdr_tree "$TREE/sanitization-report.txt")"
rm -f "$TREE/sanitization-report.txt"
# "cannot be mistaken for a sha" made checkable instead of asserted by eye: at least one character
# outside the hex alphabet. Emptiness is checked separately, because an empty token is the one
# reading that would otherwise be indistinguishable from a silent emit.
case "$HDR_C" in *[!0-9a-f]*) HDR_C_NONSHA=YES ;; *) HDR_C_NONSHA=NO ;; esac
if [ -n "$HDR_C" ] && [ "$HDR_C" = "unknown-not-a-git-worktree" ] && [ "$HDR_C_NONSHA" = YES ]; then
  ok "HDR-c non-git synthesized tree -> legible, non-empty, non-sha fallback [$HDR_C]"
else bad "HDR-c expected a non-empty non-sha fallback token, header carried [$HDR_C] (non-sha=$HDR_C_NONSHA)"; fi

echo "== VOCAB: the shipped scanner declares no vocabulary of its own =="
# What the relocation is FOR, asserted on the shipped bytes rather than trusted. The must-hit
# control runs FIRST: a predicate that found nothing and a file that is clean read identically, and
# this one is a grep over a path that a rename would silently empty.
# The predicate matches a NON-EMPTY declaration only: `PATTERNS=(` at end of line (the multi-line
# form the array used to take) or followed by anything that is not the closing paren. The empty
# `PATTERNS=()` the loader initialises is not a declaration of vocabulary and must not match.
vocab_decl() { grep -nE '^PATTERNS=\(([^)]|$)|^const DENY = \[' "$1"; }

VOCAB_SEAM="$(grep -c 'AAL_SANITIZE_WORDLIST' "$SCANNER")"
if [ "$VOCAB_SEAM" -ge 1 ]; then ok "VOCAB-b CONTROL the scanner is readable and names the seam -> $VOCAB_SEAM line(s)"
else bad "VOCAB-b CONTROL fired on nothing -- the file was never read, so VOCAB-a proves nothing"; halt; fi
VOCAB_DECL="$(vocab_decl "$SCANNER")"
if [ -z "$VOCAB_DECL" ]; then ok "VOCAB-a no PATTERNS array and no DENY literal is declared in the scanner"
else bad "VOCAB-a the scanner still declares its own vocabulary:"; printf '%s\n' "$VOCAB_DECL"; fi

# MUST-RED, on a COPY so no shipped byte is ever mutated: re-declare both forms and the predicate
# has to fire on both. Without this arm, VOCAB-a is satisfied by a predicate that matches nothing at
# all -- and "the file is clean" and "the regex is broken" read identically.
VOCAB_MUT="$TREE/.payloads/scanner-revocab.copy"
cat "$SCANNER" > "$VOCAB_MUT"
printf 'PATTERNS=(\n' >> "$VOCAB_MUT"
printf 'const DENY = [];\n' >> "$VOCAB_MUT"
VOCAB_MUT_N="$(vocab_decl "$VOCAB_MUT" | grep -c .)"
rm -f "$VOCAB_MUT"
if [ "$VOCAB_MUT_N" = 2 ]; then ok "VOCAB-c MUST-RED a copy that re-declares both forms -> $VOCAB_MUT_N hit(s)"
else bad "VOCAB-c MUST-RED expected 2 hits on the mutated copy, got $VOCAB_MUT_N"; fi

echo ""
echo "RESULT: $PASS passed, $FAIL failed (arms run: $((PASS+FAIL)))"
[ "$FAIL" -eq 0 ]

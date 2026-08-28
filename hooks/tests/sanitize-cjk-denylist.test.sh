#!/usr/bin/env bash
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
printf '{ "name": "awesome-autoloop" }\n' > "$TREE/.claude-plugin/plugin.json"
GTREE=""
cleanup(){ rm -rf "$TREE"; if [ -n "$GTREE" ]; then rm -rf "$GTREE"; fi; }
trap cleanup EXIT

WORDLIST="$TREE/.payloads/wordlist.json"
WORDLIST_BAD="$TREE/.payloads/wordlist-malformed.json"
WORDLIST_MISSING="$TREE/.payloads/wordlist-does-not-exist.json"
WORDLIST_EMPTY="$TREE/.payloads/wordlist-empty.json"

node - "$TREE" <<'NODEJS'
const fs = require('node:fs');
const T = process.argv[2];
const P = T + '/.payloads/';

const TERMS = [];
for (let i = 1; i <= 12; i++) TERMS.push('zqxdeny' + String(i).padStart(2, '0'));
const PATS = ['zqxleak[0-9]', 'zqx\\.dot'];
fs.writeFileSync(P + 'wordlist.json', JSON.stringify({ patterns: PATS, deny: TERMS }, null, 2) + '\n');
fs.writeFileSync(P + 'wordlist-malformed.json', '{');
fs.writeFileSync(P + 'wordlist-empty.json', JSON.stringify({ patterns: [], deny: [] }, null, 2) + '\n');
fs.writeFileSync(P + 'terms.txt', TERMS.join('\n') + '\n');
TERMS.forEach((t, i) => fs.writeFileSync(P + 'deny' + i + '.txt', 'a line that mentions ' + t + ' once\n'));
fs.writeFileSync(P + 'deny-all.txt', TERMS.map((t) => 'line for ' + t).join('\n') + '\n');

fs.writeFileSync(P + 'static.txt', 'a project literal zqxleak7 leaked here\n');
fs.writeFileSync(P + 'escape-hit.txt', 'the escaped pattern zqx.dot appears here\n');
fs.writeFileSync(P + 'escape-miss.txt', 'a near miss zqxXdot appears here\n');

const CJK_LINE  = 'prose line ' + '\u4e2d\u6587\u6d4b\u8bd5' + ' here';
const CJK_ID    = 'maintainer handle ' + '\u96ea\u5c71' + ' inline';
const NON_CJK   = 'punctuation \u2014 \u00b7 \u00d7 \u00b0 \u00e9 \u00bd \u2192 only';
fs.writeFileSync(P + 'cjk.txt', CJK_LINE + '\n');
fs.writeFileSync(P + 'cjkid.txt', CJK_ID + '\n');
fs.writeFileSync(P + 'nonascii.txt', NON_CJK + '\n');
fs.writeFileSync(P + 'benign.txt', 'plain ascii prose, nothing to see\n');
fs.writeFileSync(P + 'multi.txt',
  Array.from({ length: 7 }, (_, i) => 'benign subject line ' + (i + 1)).join('\n') + '\n');

// The line number here IS the ACCEPT_DENY coordinate for docs/OPERATING.md, asserted
// below before any arm runs. It was 44 and this wave re-derived it to 54; a payload left
// at the old number turns the must-green control into a real finding plus a stale entry,
// which reads like a broken ledger rather than a stale fixture.
const ACC_LINE = 54;
const mk = (l) => { const a = []; for (let i = 1; i <= 70; i++)
  a.push(i === ACC_LINE ? l : 'filler line ' + i); return a.join('\n') + '\n'; };
fs.writeFileSync(P + 'op-fresh.md', mk('row about a ' + TERMS[2]));
fs.writeFileSync(P + 'op-stale.md', mk('filler line ' + ACC_LINE));
NODEJS
[ -f "$TREE/.payloads/cjk.txt" ] || { echo "  [FAIL] payload materialisation produced nothing"; exit 1; }
[ -f "$WORDLIST" ] || { echo "  [FAIL] the synthetic wordlist was not written"; exit 1; }

# The payload above places the accepted line at 54 because that is the coordinate the scanner's
# ACCEPT_DENY names. Assert it here rather than discovering it as two confusing arm failures: a
# ledger entry that moves makes the must-green control report a real finding AND a stale entry.
ACC_COORD_HITS=$(grep -c "'docs/OPERATING.md:54'" "$SCANNER")
[ "$ACC_COORD_HITS" = 1 ] || {
  echo "  [FAIL] setup: the scanner's ACCEPT_DENY no longer carries docs/OPERATING.md:54 (found $ACC_COORD_HITS) — move ACC_LINE in this fixture to the new coordinate"
  exit 1
}

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

# Keyed on ACCEPT_DENY, not ACCEPT_CJK. The CJK ledger ships EMPTY now, so an arm keyed on it has
# an empty population and can never fail again — the same vacuity this suite's own board-field
# assertions were re-purposed to avoid. The BEHAVIOUR under test is unchanged and is the load-bearing
# one: the ledger is walked as a LIST, so an entry whose subject stopped matching reports stale
# instead of rotting unnoticed. ACCEPT_DENY still carries a population, so it can still answer.
echo "== STALE: the accepted ledger is walked as a LIST, so an entry that stops matching goes RED =="
reset_tree; cp "$TREE/.payloads/op-stale.md" "$TREE/docs/OPERATING.md"
expect "STALE-a accepted line no longer matches -> stale-accepted 1 (the must-red for the ledger)" 1 "patterns 0 · cjk 0 · denylist 0 · stale-accepted 1"
reset_tree; cp "$TREE/.payloads/op-fresh.md" "$TREE/docs/OPERATING.md"
expect "STALE-b same file, accepted line restored -> stale-accepted 0 (must-green control)" 0 "patterns 0 · cjk 0 · denylist 0 · stale-accepted 0"
SCAN_WL=""
reset_tree; cp "$TREE/.payloads/op-fresh.md" "$TREE/docs/OPERATING.md"
expect "STALE-c same file with NO wordlist -> stale-accepted 0 (an unrun arm's entries are not stale)" 0 "patterns 0 · cjk 0 · denylist 0 · stale-accepted 0"
SCAN_WL="$WORDLIST"

echo "== ROOT: the scanner refuses a tree that is not this repository, AND writes nothing there =="
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
reset_tree; plant benign.txt note.txt
SCAN_WL="$WORDLIST"; scan
if [ "$SCAN_WLHDR" = "$WORDLIST (patterns 2, deny 12, address-scoped 0)" ]; then
  ok "WL-a configured -> header names the resolved path AND all three counts [$SCAN_WLHDR]"
else bad "WL-a expected [$WORDLIST (patterns 2, deny 12, address-scoped 0)], header carried [$SCAN_WLHDR]"; fi
if [ "$SCAN_RESULT" = "PASS (0 findings)" ]; then ok "WL-a configured, clean tree -> RESULT: $SCAN_RESULT"
else bad "WL-a expected [PASS (0 findings)], got [$SCAN_RESULT]"; fi

reset_tree; plant benign.txt note.txt
SCAN_WL="$WORDLIST_MISSING"; scan
if [ "$SCAN_WLHDR" = "not configured" ]; then ok "WL-b absent -> header reads the literal [wordlist: $SCAN_WLHDR]"
else bad "WL-b expected header [not configured], carried [$SCAN_WLHDR]"; fi
if [ "$SCAN_RESULT" = "PARTIAL PASS (0 findings; 2 arms not configured)" ]; then
  ok "WL-b absent, clean tree -> RESULT: $SCAN_RESULT"
else bad "WL-b expected [PARTIAL PASS (0 findings; 2 arms not configured)], got [$SCAN_RESULT]"; fi
if [ "$SCAN_RC" = 0 ]; then ok "WL-b absent -> exit 0 (a public user with no wordlist gets a green lane)"
else bad "WL-b expected rc=0, got rc=$SCAN_RC"; fi
if [ "$SCAN_PATS" = "0 (wordlist not configured, 0 terms)" ]; then
  ok "WL-b absent, no OS username -> the summary says so too [Patterns checked: $SCAN_PATS]"
else bad "WL-b expected [0 (wordlist not configured, 0 terms)], got [$SCAN_PATS]"; fi
if [ "$SCAN_RESULT" != "PASS (0 findings)" ]; then
  ok "WL-b the absent reading is NOT byte-identical to a full pass"
else bad "WL-b absent state produced a full-pass result line"; fi

reset_tree; plant benign.txt note.txt
rm -f "$TREE/sanitization-report.txt"
( cd "$TREE" && env -u CI -u USER USERNAME=zqxwluser AAL_SANITIZE_WORDLIST="$WORDLIST_MISSING" \
    bash "$SCANNER" >/dev/null 2>&1 ); WLAUG_RC=$?
WLAUG_PATS=$(sed -n 's/^Patterns checked: //p' "$TREE/sanitization-report.txt" 2>/dev/null)
rm -f "$TREE/sanitization-report.txt"
if [ "$WLAUG_PATS" = "1 (wordlist not configured, 0 terms)" ] && [ "$WLAUG_RC" = 0 ]; then
  ok "WL-e absent + an OS username -> [Patterns checked: $WLAUG_PATS], rc=$WLAUG_RC (the augment survives)"
else bad "WL-e expected [1 (wordlist not configured, 0 terms)] rc=0, got [$WLAUG_PATS] rc=$WLAUG_RC"; fi

reset_tree; plant cjk.txt prose.txt
SCAN_WL="$WORDLIST_MISSING"; scan
if [ "$SCAN_RC" = 1 ] && [ "$SCAN_RESULT" = "FAIL (1 findings; 2 arms not configured)" ]; then
  ok "WL-d absent + a real CJK finding -> rc=1 and RESULT: $SCAN_RESULT"
else bad "WL-d expected rc=1 and [FAIL (1 findings; 2 arms not configured)], got rc=$SCAN_RC [$SCAN_RESULT]"; fi

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
reset_tree; plant multi.txt subject.txt
EMPTY_ALL=$(awk 'END{print NR}' "$TREE/.claude-plugin/plugin.json" "$TREE/templates"/*)
echo "  (derived) lines a universal matcher would report on this tree: $EMPTY_ALL"
SCAN_WL="$WORDLIST_EMPTY"
expect "EMPTY-a empty arrays over a $EMPTY_ALL-line tree -> patterns 0 (INERT, not universal)" 0 "patterns 0 · cjk 0 · denylist 0 · stale-accepted 0"

reset_tree; plant deny-all.txt all.txt
expect "EMPTY-b empty deny array over the same 12-term plant -> denylist 0 (F-8[all] reads 12)" 0 "patterns 0 · cjk 0 · denylist 0 · stale-accepted 0"
SCAN_WL="$WORDLIST"

reset_tree; plant multi.txt subject.txt
EMPTY_MUT="$TREE/.payloads/scanner-unguarded.copy"
sed 's/^if \[ "\$PATTERN_COUNT" -gt 0 \] && \[ -n "\$SCAN_EXISTING" \]; then$/if [ 1 = 1 ]; then/' "$SCANNER" > "$EMPTY_MUT"
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

EMPTY_PF="$TREE/.payloads/patfile-empty"
REAL_PF="$TREE/.payloads/patfile-real"
EMPTY_ARR=()
printf '%s\n' ${EMPTY_ARR[@]+"${EMPTY_ARR[@]}"} > "$EMPTY_PF"
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
hdr_tree() {
  sed -n "s/^.*sanitization report (\(.*\))[[:space:]]*\$/\1/p" "$1" | sed "s/^.*, //"
}
run_in()  { ( cd "$1" && env -u CI -u USER -u USERNAME -u AAL_SANITIZE_WORDLIST \
                bash "$SCANNER" >/dev/null 2>&1 ); }

GTREE="$(mktemp -d "$HOME/.aal-sanhdr-XXXXXX")"
mkdir -p "$GTREE/.claude-plugin" "$GTREE/templates"
printf '{ "name": "awesome-autoloop" }\n' > "$GTREE/.claude-plugin/plugin.json"
printf 'plain ascii prose, nothing to see\n' > "$GTREE/templates/note.txt"
printf 'sanitization-report.txt\n' > "$GTREE/.gitignore"
git -C "$GTREE" init -q >/dev/null 2>&1
git -C "$GTREE" add -A >/dev/null 2>&1
git -C "$GTREE" -c user.name=aal-fixture -c user.email=aal-fixture@example.invalid \
  -c commit.gpgsign=false commit -q -m "fixture tree" >/dev/null 2>&1
GSHA="$(git -C "$GTREE" rev-parse HEAD 2>/dev/null)"
if [ -z "$GSHA" ]; then bad "HDR setup -- could not build a git-backed scan tree (no sha)"; halt; fi
GSTATUS="$(git -C "$GTREE" status --porcelain 2>/dev/null)"
if [ -n "$GSTATUS" ]; then bad "HDR setup -- the fixture git tree is not clean: [$GSTATUS]"; halt; fi

run_in "$GTREE"; HDR_A="$(hdr_tree "$GTREE/sanitization-report.txt")"
rm -f "$GTREE/sanitization-report.txt"
if [ "$HDR_A" = "$GSHA" ]; then ok "HDR-a git tree, CLEAN -> header names the commit [$HDR_A]"
else bad "HDR-a git tree, CLEAN -> expected [$GSHA], header carried [$HDR_A]"; fi

printf 'a second benign ascii line\n' >> "$GTREE/templates/note.txt"
run_in "$GTREE"; HDR_B="$(hdr_tree "$GTREE/sanitization-report.txt")"
rm -f "$GTREE/sanitization-report.txt"
if [ "$HDR_B" = "$GSHA-dirty" ]; then ok "HDR-b same tree, uncommitted edit -> header says so [$HDR_B]"
else bad "HDR-b expected [$GSHA-dirty], header carried [$HDR_B]"; fi

reset_tree; plant benign.txt note.txt
run_in "$TREE"; HDR_C="$(hdr_tree "$TREE/sanitization-report.txt")"
rm -f "$TREE/sanitization-report.txt"
case "$HDR_C" in *[!0-9a-f]*) HDR_C_NONSHA=YES ;; *) HDR_C_NONSHA=NO ;; esac
if [ -n "$HDR_C" ] && [ "$HDR_C" = "unknown-not-a-git-worktree" ] && [ "$HDR_C_NONSHA" = YES ]; then
  ok "HDR-c non-git synthesized tree -> legible, non-empty, non-sha fallback [$HDR_C]"
else bad "HDR-c expected a non-empty non-sha fallback token, header carried [$HDR_C] (non-sha=$HDR_C_NONSHA)"; fi

echo "== VOCAB: the shipped scanner declares no vocabulary of its own =="
vocab_decl() { grep -nE '^PATTERNS=\(([^)]|$)|^const DENY = \[' "$1"; }

VOCAB_SEAM="$(grep -c 'AAL_SANITIZE_WORDLIST' "$SCANNER")"
if [ "$VOCAB_SEAM" -ge 1 ]; then ok "VOCAB-b CONTROL the scanner is readable and names the seam -> $VOCAB_SEAM line(s)"
else bad "VOCAB-b CONTROL fired on nothing -- the file was never read, so VOCAB-a proves nothing"; halt; fi
VOCAB_DECL="$(vocab_decl "$SCANNER")"
if [ -z "$VOCAB_DECL" ]; then ok "VOCAB-a no PATTERNS array and no DENY literal is declared in the scanner"
else bad "VOCAB-a the scanner still declares its own vocabulary:"; printf '%s\n' "$VOCAB_DECL"; fi

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

#!/usr/bin/env bash
# sanitize-check.sh — the public-flip sanitization gate (AC-5).
# Scans the SHIPPED tree for secret / identity / project-leak literals, CJK prose and domain terms,
# and EMITS A REPORT (files scanned + every hit VERBATIM + the exclusion note). The author reads this
# report before publishing. Exit 0 on PASS (0 findings), 1 on FAIL, 2 on an unusable instrument.
#
# The forbidden-pattern set and the domain denylist are LOADED from a wordlist file (see WORDLIST
# below), not declared here, so this instrument can ship without shipping the literals it blocks.
# With no wordlist it runs its wordlist-free arms and says so — PARTIAL PASS, exit 0 — rather than
# reporting a clean tree about checks it never ran.
#
# 🔴 stdout carries the SUMMARY half ONLY — files scanned, checks run, counts, class breakdown, the
# file names, the result. The VERBATIM hit lines reach "$REPORT" alone. .github/workflows/ci.yml runs
# this on every push across three lanes and this repository's Actions logs are anonymously readable,
# so an instrument that exists to keep unscrubbed bytes off the internet must not print them into a
# public log. This is WHERE the hits are written, never WHAT is written: the report file still
# carries every hit, unsampled and untruncated.
#
# Run from the repo root: bash bin/sanitize-check.sh
set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

# FAIL-CLOSED on the resolved scan root. The `|| pwd` above means that running this script from a
# directory that is not a git repository resolves ROOT to THAT directory — and the scanner would then
# scan it and write a full verbatim report into it. Measured first-hand: invoked from a home
# directory it scanned ~43 MB and wrote the report there. A "does ROOT contain a SCAN_PATHS entry"
# check would NOT have caught that (the same home directory has both bin/ and templates/), so the
# marker is this repository's own plugin manifest. Refuse instead of falling back — this path writes
# nothing, which is the half a bare exit code cannot express.
if [ ! -f "$ROOT/.claude-plugin/plugin.json" ] ||
   ! grep -q '"awesome-autoloop"' "$ROOT/.claude-plugin/plugin.json" 2>/dev/null; then
  echo "sanitize-check: FATAL — the resolved scan root is not this repository:" >&2
  echo "  $ROOT" >&2
  echo "sanitize-check: expected \$ROOT/.claude-plugin/plugin.json naming awesome-autoloop." >&2
  echo "sanitize-check: run it from inside the repository — cd <repo> && bash bin/sanitize-check.sh" >&2
  echo "sanitize-check: nothing was scanned and no report was written." >&2
  exit 2
fi

cd "$ROOT" || exit 2

# node is a hard requirement of BOTH the wordlist loader below and the CJK / denylist pass further
# down, so this check sits above the FIRST of them rather than beside the second. FAIL-CLOSED: a
# gate that cannot evaluate must not report a tree as clean.
if ! command -v node >/dev/null 2>&1; then
  echo "sanitize-check: FATAL — node is required for the wordlist loader and the CJK / denylist pass, and was not found." >&2
  echo "sanitize-check: install node >= 18 and re-run. Refusing to report a tree as clean unscanned." >&2
  exit 2
fi

# Scope: exactly these paths (the artifact that ships public). docs/OPERATING.md and
# docs/QUICKSTART.md are named INDIVIDUALLY, because they are tracked and they DO ship — the
# exclusion's own recorded reason ("the specs legitimately name what they scrub and never ship
# public") is true of docs/product-specs/ and false of those two. docs/** is deliberately NOT added
# as a directory: docs/product-specs/ stays excluded AND untracked (USER LOCK 2026-06-21).
SCAN_PATHS=".claude-plugin .github hooks agents skills templates examples bin README.md LICENSE docs/OPERATING.md docs/QUICKSTART.md"

# The OS username is resolved at runtime (never hardcoded here, so the doc carries no identity).
OS_USER="${USERNAME:-${USER:-}}"

# THE WORDLIST. This instrument ships; its VOCABULARY does not. The forbidden-pattern set and the
# domain-term denylist are LOADED from the file below instead of being declared here, so that the
# published tree carries a working leak gate that spells out none of the literals it blocks.
#
# The seam is an env var WITH a default, never a bare path. A git worktree does not contain the main
# checkout's ignored files, so a bare "$ROOT/.claude/..." resolves to nothing in exactly the trees
# this is developed in — and the scanner would then report "not configured" to someone who has a
# wordlist. That failure is silent and it reads identically to the public behaviour.
WORDLIST="${AAL_SANITIZE_WORDLIST:-$ROOT/.claude/sanitize-wordlist.json}"

# Three states, and the middle one is why this is a loader and not an include:
#   resolves and parses     -> both vocabulary arms run exactly as they did in-file.
#   ABSENT                  -> both are skipped AND SAID SO, in the summary, in the result line and
#                              in the report header. A public user with no wordlist gets a green
#                              lane, but never one BYTE-IDENTICAL to a full pass: an instrument that
#                              fails silently by passing is worse than no instrument. Absence alone
#                              never sets the exit code -- findings from the arms that DID run still
#                              do, or the hosted lanes would certify nothing.
#   present but unparseable -> FATAL, exit 2, no report written. Same shape as the node-absent
#                              branch above: a wordlist that half-parsed is worse than one that is
#                              absent, because the absent case announces itself.
PATTERNS=()
# The count is tracked explicitly rather than read back as ${#PATTERNS[@]}: it reaches the summary,
# and this file must run on the macOS lane's bash 3.2, where expanding an EMPTY array under `set -u`
# is not safe. PATTERNS is now genuinely emptiable.
PATTERN_COUNT=0
WORDLIST_OK=0
WORDLIST_PATTERNS=0
WORDLIST_TERMS=0
if [ -e "$WORDLIST" ]; then
  WL_OUT=$(mktemp)
  # Program on stdin, data in argv -- the same invocation form the CJK pass uses below, and the one
  # that behaves identically on ubuntu, macOS and Windows Git-Bash.
  node - "$WORDLIST" > "$WL_OUT" 2>&1 <<'NODEJS'
const fs = require('node:fs');
const wl = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
// Validate the SHAPE, not just the parse. An entry that is empty, non-string or multi-line is not a
// usable pattern, and the empty string is actively dangerous: `grep -f` treats an empty line as a
// pattern that matches EVERY line, so a single stray "" would report the whole tree as findings.
const arr = (v, name) => {
  if (!Array.isArray(v)) throw new Error(name + ': expected an array');
  for (const e of v) {
    if (typeof e !== 'string' || e === '') throw new Error(name + ': every entry is a non-empty string');
    if (/[\r\n]/.test(e)) throw new Error(name + ': entries are single-line');
  }
  return v;
};
const pats = arr(wl.patterns, 'patterns');
const deny = arr(wl.deny, 'deny');
// Line 1 is the two counts; every line after it is one pattern, verbatim.
process.stdout.write([pats.length + ' ' + deny.length, ...pats].join('\n') + '\n');
NODEJS
  WL_RC=$?
  if [ "$WL_RC" != 0 ]; then
    echo "sanitize-check: FATAL — the wordlist is present but did not load: $WORDLIST" >&2
    sed -n '1,20p' "$WL_OUT" >&2
    echo "sanitize-check: fix or remove it and re-run. Refusing to report a tree as clean unscanned." >&2
    rm -f "$WL_OUT"
    exit 2
  fi
  # Read from a FILE, never from a pipeline: `while read` on the right-hand side of a pipe runs in a
  # subshell, and the array built there would not survive it.
  WL_FIRST=1
  while IFS= read -r wl_line; do
    if [ "$WL_FIRST" = 1 ]; then
      WORDLIST_PATTERNS=${wl_line%% *}
      WORDLIST_TERMS=${wl_line##* }
      WL_FIRST=0
    else
      PATTERNS+=("$wl_line")
      PATTERN_COUNT=$((PATTERN_COUNT + 1))
    fi
  done < "$WL_OUT"
  rm -f "$WL_OUT"
  WORDLIST_OK=1
fi

# Add the OS username as a forbidden pattern only OUTSIDE CI, and only if set and >=3 chars.
# In CI the OS login is a generic service account (GitHub Actions: `runner` on ubuntu/macOS,
# `runneradmin` on windows) that also occurs benignly across the tree -> augmenting there is a false
# positive. The augment guards ONLY the local runner's OWN OS identity (a third party's name in file
# content is the static PATTERNS set's job), and in CI that identity is definitionally the service
# account, not the author -> skipping regresses nothing. `${CI:-}` fires on GitHub's default CI=true.
if [ -z "${CI:-}" ] && [ -n "$OS_USER" ] && [ "${#OS_USER}" -ge 3 ]; then
  PATTERNS+=("$(printf '%s' "$OS_USER" | sed 's/[].[^$*\/]/\\&/g')")
  PATTERN_COUNT=$((PATTERN_COUNT + 1))
fi

TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
REPORT="$ROOT/sanitization-report.txt"

# SELF-EXCLUDE: this script's own accepted-line keys, and the prose describing the generic English
# the denylist accepts, still name some of the terms it searches FOR — they are the scanner's logic,
# NOT shipped content to vet. A scanner doesn't scan itself; excluding it is correct, not a loophole.
# (Before the wordlist moved out, this sentence also had to cover the PATTERNS array and the denylist
# array. Those no longer live here, so the exclusion is narrower than it was — but not removable.)
SELF="${BASH_SOURCE[0]}"
SELF_BASE=$(basename "$SELF")

# Files-scanned count: ONE find over all scan paths (the per-path find-IN-A-LOOP was part of the spew).
# SC2086: SCAN_PATHS is a space-separated path LIST that MUST split into separate find args.
# shellcheck disable=SC2086
FILES_SCANNED=$(find $SCAN_PATHS -type f -not -path '*/docs/product-specs/*' 2>/dev/null \
  | grep -cv "/$SELF_BASE\$" | tr -d ' ')

# SINGLE-PASS scan. The old form (files×patterns nested loop, ~1,771 grep spawns) was pathologically
# slow on Windows/Git-Bash MSYS (timed out at 120s). This is ONE recursive grep over the whole scan
# set, with docs/product-specs/ and this script excluded by grep's own flags — no per-file /
# per-pattern spawning.
#
# GUARDED ON THE COUNT, and the guard is load-bearing rather than defensive: `printf '%s\n'` with
# ZERO arguments emits one EMPTY line, and an empty line in a grep -f pattern file matches EVERY
# line. Before the wordlist moved out, PATTERNS could not be empty and this was unreachable; a
# hosted lane now runs with no wordlist AND with the CI guard skipping the username augment, which
# is exactly the empty case. Unguarded, that lane would report every line of the tree as a finding.
HITLINES=""
if [ "$PATTERN_COUNT" -gt 0 ]; then
  PATFILE=$(mktemp)
  printf '%s\n' ${PATTERNS[@]+"${PATTERNS[@]}"} > "$PATFILE"
  # The scan: ONE grep -rniE, docs/product-specs + self excluded by grep's flags (SCAN_PATHS may
  # include bare files like README.md — grep -r accepts a mix of files + dirs). Each non-empty line
  # is a hit path:lineno:text.
  # SC2086: SCAN_PATHS must word-split into separate grep -r roots.
  # shellcheck disable=SC2086
  HITLINES=$(grep -rniE -f "$PATFILE" --exclude-dir=product-specs --exclude="$SELF_BASE" \
    $SCAN_PATHS 2>/dev/null || true)
  rm -f "$PATFILE"
fi

HIT_COUNT=0
[ -n "$HITLINES" ] && HIT_COUNT=$(printf '%s\n' "$HITLINES" | grep -c .)

# ---------------------------------------------------------------------------------------------
# CJK-range + domain-denylist pass. Delegated to node because the shell alternative is wrong in the
# expensive direction: a bracket expression [<start>-<end>] is locale-dependent and on this box also
# matches an em-dash, a middle dot and emoji — it read 1775 hits / 143 files where the true value is
# 26 / 10. `grep -P` is not an option either: it returns a silent 0 here. node's availability is
# checked near the top, above the wordlist loader that also needs it.
#
# The CJK arm is WORDLIST-FREE by construction and always runs; the denylist arm is the wordlist's,
# and it receives the resolved path or the empty string.
NODE_OUT=$(mktemp)
WORDLIST_ARG=""
[ "$WORDLIST_OK" = 1 ] && WORDLIST_ARG="$WORDLIST"
# Program on stdin, data in argv: the one invocation form that behaves identically on ubuntu, macOS
# and Windows Git-Bash. A temp-file program path would be MSYS-translated on the Windows lane.
# SC2086: SCAN_PATHS must word-split into separate argv entries.
# shellcheck disable=SC2086
node - "$SELF_BASE" "$WORDLIST_ARG" $SCAN_PATHS > "$NODE_OUT" 2>&1 <<'NODEJS'
const fs = require('node:fs');
const path = require('node:path');
const [selfBase, wordlistPath, ...scanPaths] = process.argv.slice(2);

// CJK detection. A shell bracket expression [<start>-<end>] is locale-dependent and matches
// em-dash, middle dot and emoji on this box — it read 1775 hits / 143 files where the true value
// is 26 / 10. Use explicit codepoint ranges.
const CJK = /[\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF\u3040-\u30FF\uAC00-\uD7AF]|[\uD840-\uD87F][\uDC00-\uDFFF]/;

// Domain-term denylist — LOADED, not declared. A FLOOR, never a ceiling: the list may GROW, never
// shrink, and it lives in the wordlist file so the published tree spells out none of its terms.
// Matched case-insensitively as substrings, so plurals and compounds ("shards", "verifiers") hit
// too. Empty and inert when no wordlist resolved; DENY_ON is what the report says so about.
//
// (The 4-space indent on the two accepted-line lists below is a leftover from a shape predicate
// that used to have to tell them apart from a PATTERNS array declared in this file. That array now
// lives in the wordlist, so nothing in this file is at risk of being conflated with it any more.
// The indent is left alone rather than re-flowed, because re-flowing it is churn with no reader.)
const DENY = wordlistPath ? JSON.parse(fs.readFileSync(wordlistPath, 'utf8')).deny : [];
const DENY_ON = Boolean(wordlistPath);

// ACCEPTED lines — consulted by these TWO arms ONLY, never by the PATTERNS set above, which keeps
// zero exceptions. Every entry is one LINE (never a directory, never a glob), enumerated by running
// this check and reading each hit, and justified individually in the Batch-1 PR body.
//   CJK class: board-dialect PATTERN LITERALS (`别名` `问题` `修复` `状态:` inside a regex or a grep)
//   and the comments that quote the literal the adjacent line matches on — doc<->code fidelity,
//   the same ground docs/OPERATING.md:69 was ruled on and re-probed in 2026-07-10.
//   DENY class: generic English with no project referent — "curl the live endpoint or shard",
//   "exported shards are NOT open data", "an audit's finders/verifiers often use curl/grep".
const ACCEPT_CJK = new Set([
    'hooks/backlog-drift-check.mjs:81', 'hooks/backlog-drift-guard.sh:27',
    'hooks/backlog-drift-guard.sh:28', 'hooks/backlog-sop-validate.mjs:152',
    'hooks/backlog-sop-validate.mjs:343', 'hooks/backlog-sop-validate.mjs:345',
    'hooks/backlog-sop-validate.mjs:346', 'hooks/backlog-sop-validate.mjs:379',
    'hooks/block-backlog-status-drift.mjs:24', 'hooks/block-backlog-status-drift.mjs:25',
    'hooks/block-backlog-status-drift.mjs:32', 'hooks/block-backlog-status-drift.mjs:42',
    'hooks/block-backlog-status-drift.mjs:43', 'hooks/block-malformed-new-backlog-card.mjs:68',
    'hooks/block-malformed-new-backlog-card.mjs:69', 'hooks/block-malformed-new-backlog-card.mjs:70',
    'hooks/lib/premise-target.mjs:49', 'hooks/lib/premise-target.mjs:63',
    'hooks/require-backlog-reconciled-before-merge.cjs:32',
    'hooks/tests/empty-board-and-comment-strip.test.sh:103',
    'hooks/tests/empty-board-and-comment-strip.test.sh:105',
    'skills/backlog-reconcile/backlog-reconcile.mjs:76',
    'skills/backlog-reconcile/backlog-reconcile.mjs:77',
    'examples/roster-board-aware.example.sh:41',
    'examples/roster-board-aware.example.sh:65', 'docs/OPERATING.md:69',
]);
const ACCEPT_DENY = new Set([
    'hooks/backlog-drift-check.mjs:92', 'hooks/block-cleaned-data-commit.sh:3',
    'hooks/block-cleaned-data-commit.sh:58', 'hooks/render-finding-playwright-guard.sh:6',
    'hooks/render-finding-playwright-guard.sh:40', 'hooks/require-premise-verified-before-dev.sh:6',
    'hooks/require-premise-verified-before-dev.sh:48', 'templates/runbooks/TEMPLATE.md:15',
    'templates/runbooks/TEMPLATE.md:44', 'docs/OPERATING.md:44',
]);

function walk(p, out) {
  let st;
  try { st = fs.statSync(p); } catch { return; }
  if (st.isDirectory()) {
    if (path.basename(p) === 'product-specs') return;   // USER LOCK 2026-06-21
    for (const e of fs.readdirSync(p).sort()) walk(p + '/' + e, out);
  } else if (st.isFile() && path.basename(p) !== selfBase) {
    out.push(p);
  }
}

const files = [];
for (const p of scanPaths) walk(p, files);

const hits = [];                       // {key, cls, path, line, text}
const usedCjk = new Set(), usedDeny = new Set();
for (const f of files) {
  let txt;
  try { txt = fs.readFileSync(f, 'utf8'); } catch { continue; }
  const lines = txt.split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    const key = f + ':' + (i + 1), lower = lines[i].toLowerCase();
    if (CJK.test(lines[i])) {
      if (ACCEPT_CJK.has(key)) usedCjk.add(key);
      else hits.push({ cls: 'cjk', path: f, line: i + 1, text: lines[i] });
    }
    const terms = DENY.filter((t) => lower.includes(t.toLowerCase()));
    if (terms.length) {
      if (ACCEPT_DENY.has(key)) usedDeny.add(key);
      else hits.push({ cls: 'denylist[' + terms.join(',') + ']', path: f, line: i + 1, text: lines[i] });
    }
  }
}

// Second pass over the LIST, not over the hits. A hit-driven matcher only ever visits lines that
// matched, so an accepted entry that has gone stale is never revisited and rots invisibly. Walking
// the list turns that silence into a failure.
// An entry is only CHECKABLE when its file is in the scanned set: a deleted file hides nothing, and
// gating on presence is also what lets a fixture run this scanner over a synthesized tree — where
// none of these paths exist — without every entry reporting stale.
// The same predicate extends one step further now that the denylist is loaded: an entry is checkable
// only while its ARM is running as well as while its file is present. Without this the wordlist-free
// configuration reports all ten ACCEPT_DENY entries as stale on a perfectly clean tree — ten
// findings that describe the loader, not the content.
const seen = new Set(files);
const checkable = (k) => seen.has(k.slice(0, k.lastIndexOf(':')));
const staleDeny = DENY_ON
  ? [...ACCEPT_DENY].filter((k) => checkable(k) && !usedDeny.has(k)).map((k) => 'denylist ' + k)
  : [];
const stale = [...[...ACCEPT_CJK].filter((k) => checkable(k) && !usedCjk.has(k)).map((k) => 'cjk ' + k),
  ...staleDeny];

const out = [];
out.push('F\t' + files.length);
out.push('T\t' + DENY.length);
out.push('A\t' + (ACCEPT_CJK.size + ACCEPT_DENY.size));
out.push('C\t' + hits.filter((h) => h.cls === 'cjk').length);
out.push('D\t' + hits.filter((h) => h.cls !== 'cjk').length);
out.push('O\t' + stale.length);
for (const f of [...new Set(hits.map((h) => h.path))].sort()) out.push('N\t' + f);
for (const h of hits) out.push('V\t' + h.path + ':' + h.line + ': [' + h.cls + '] ' + h.text);
for (const s of stale) out.push('S\t' + s);
process.stdout.write(out.join('\n') + '\n');
NODEJS
NODE_RC=$?
if [ "$NODE_RC" != 0 ]; then
  echo "sanitize-check: FATAL — the CJK / denylist pass exited $NODE_RC. Not reporting clean." >&2
  sed -n '1,20p' "$NODE_OUT" >&2
  rm -f "$NODE_OUT"
  exit 2
fi

nfield() { awk -F'\t' -v k="$1" '$1==k {print $2; exit}' "$NODE_OUT"; }
NODE_FILES=$(nfield F)
DENY_TERMS=$(nfield T)
ACCEPTED=$(nfield A)
CJK_COUNT=$(nfield C)
DENY_COUNT=$(nfield D)
STALE_COUNT=$(nfield O)

# The find above and the walk inside node are two enumerations of one scope. Nothing compares them by
# default, so a divergence would be silent and would shrink the scanned set in whichever direction
# was wrong. Compare them and fail loudly instead.
if [ "$NODE_FILES" != "$FILES_SCANNED" ]; then
  echo "sanitize-check: FATAL — scope divergence: find=$FILES_SCANNED node=$NODE_FILES." >&2
  rm -f "$NODE_OUT"
  exit 2
fi

TOTAL=$((HIT_COUNT + CJK_COUNT + DENY_COUNT + STALE_COUNT))
FILE_NAMES=$(
  { [ -n "$HITLINES" ] && printf '%s\n' "$HITLINES" | cut -d: -f1
    awk -F'\t' '$1=="N" {print $2}' "$NODE_OUT"
  } | sort -u
)

# The report header NAMES THE TREE IT DESCRIBES, beside the timestamp it already carried.
# Derived HERE, in the header block, and never further up: .github/workflows/ci.yml points at the
# CI env-var guard above BY LINE NUMBER, and an insertion anywhere above that guard moves it. The
# invariant is that re-deriving that guard's coordinate BY CONTENT returns byte-identical output
# across this edit -- so this comment deliberately does not spell the token it would be swept by.
#
# Three failure modes, each of which a bare `git rev-parse HEAD` passes:
#  (i)   NON-GIT TREE. The fixtures synthesize a scan tree outside any repository and a git-archive
#        export carries no .git at all, so a bare rev-parse reddens those arms -- and reddens them
#        for the wrong reason. Hence the same `2>/dev/null || <fallback>` shape as the ROOT= line
#        near the top. The fallback is legible, non-empty and cannot be read as a sha: an EMPTY
#        field is byte-indistinguishable from an emit that silently returned nothing.
#  (ii)  BOTH WORLDS. One arm cannot tell "the fallback works" from "the fallback was never
#        reached", so the fixture asserts the git tree AND the synthesized tree, and prints both.
#  (iii) DIRTY TREE. `git rev-parse HEAD` returns the last COMMIT's sha however many uncommitted
#        edits sit on top of it, so a report scanned from a dirty tree would be headed with a sha
#        describing OTHER BYTES than the ones scanned -- and the two headers would be identical.
#        The marker is derived in this same block, and only once a sha actually resolved:
#        `git status --porcelain` is empty in a non-git tree too, so gating it on the sha is what
#        keeps "clean" and "not a worktree" from collapsing into one reading.
# Computed ONCE, so the report file and stdout carry the same header.
UNKNOWN_TREE='unknown-not-a-git-worktree'
TREE_SHA=$(git rev-parse HEAD 2>/dev/null || printf '%s' "$UNKNOWN_TREE")
if [ "$TREE_SHA" != "$UNKNOWN_TREE" ] && [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  TREE_SHA="$TREE_SHA-dirty"
fi

# The report header NAMES THE WORDLIST beside the tree it already names, and this is the ONLY thing
# that makes a sign-off checkable. The two people who sign a sanitization off read a REPORT, never
# the wordlist; after the vocabulary moved out of this file, two reports over the same tree can
# describe two different scans. A signer holding a "not configured" header is signing a report about
# a scan that did not run the arm being certified — and on a hosted lane, which checks out no
# .claude/, "not configured" is the NORMAL reading.
if [ "$WORDLIST_OK" = 1 ]; then
  WORDLIST_HDR="$WORDLIST (patterns $WORDLIST_PATTERNS, deny $WORDLIST_TERMS)"
  PATTERNS_NOTE="(secret / identity / project-leak / machine-path classes)"
  ARMS_NOTE=""
else
  WORDLIST_HDR="not configured"
  PATTERNS_NOTE="(wordlist not configured, 0 terms)"
  ARMS_NOTE="; 2 arms not configured"
fi

# The SUMMARY half — written to BOTH the report and stdout.
summary_half() {
  echo "Awesome Autoloop — sanitization report ($TS, $TREE_SHA)"
  echo "wordlist: $WORDLIST_HDR"
  echo "Scanned paths: $SCAN_PATHS"
  echo "Excluded:      docs/product-specs/** (untracked design specs — not part of the public artifact)"
  echo "Files scanned: $FILES_SCANNED"
  echo "Patterns checked: $PATTERN_COUNT $PATTERNS_NOTE"
  echo "CJK range check:  ON (explicit codepoint ranges)"
  echo "Domain denylist:  $DENY_TERMS term(s)"
  echo "Accepted lines:   $ACCEPTED (CJK pattern-literals + generic-English denylist uses; PATTERNS has none)"
  echo ""
  echo "Findings by class: patterns $HIT_COUNT · cjk $CJK_COUNT · denylist $DENY_COUNT · stale-accepted $STALE_COUNT"
  if [ "$TOTAL" -eq 0 ]; then
    echo "Files with findings: <none>"
    echo ""
    # PARTIAL PASS, never PASS, when a vocabulary arm did not run: the two readings must not be
    # byte-identical, or this is a tool that fails silently by passing.
    if [ "$WORDLIST_OK" = 1 ]; then
      echo "RESULT: PASS (0 findings)"
    else
      echo "RESULT: PARTIAL PASS (0 findings$ARMS_NOTE)"
    fi
  else
    echo "Files with findings:"
    printf '%s\n' "$FILE_NAMES" | while IFS= read -r f; do [ -n "$f" ] && echo "  $f"; done
    echo ""
    # Findings still FAIL with no wordlist. The arms that DID run — the CJK range and the runtime
    # username augment — are precisely the ones the hosted lanes exist to certify; a "PARTIAL PASS"
    # over a tree with real findings would leave them certifying nothing.
    echo "RESULT: FAIL ($TOTAL findings$ARMS_NOTE)"
  fi
}

# Report file = summary + EVERY hit verbatim, unsampled and untruncated (the locked report form).
summary_half > "$REPORT"
{
  echo ""
  echo "VERBATIM HITS (this half is the reason the report file is untracked; it is never echoed):"
  if [ "$TOTAL" -eq 0 ]; then
    echo "  <none>"
  else
    [ -n "$HITLINES" ] && printf '%s\n' "$HITLINES" | grep . | while IFS= read -r h; do echo "  [patterns] $h"; done
    awk -F'\t' '$1=="V" {sub(/^V\t/,""); print "  " $0}' "$NODE_OUT"
    awk -F'\t' '$1=="S" {print "  [stale-accepted] " $2 " — accepted line no longer matches; re-justify or drop it"}' "$NODE_OUT"
  fi
} >> "$REPORT"

# stdout = the summary half ONLY.
summary_half
echo ""
echo "Verbatim hits: $REPORT (untracked; not echoed here — CI logs are public)"

rm -f "$NODE_OUT"
[ "$TOTAL" -eq 0 ]

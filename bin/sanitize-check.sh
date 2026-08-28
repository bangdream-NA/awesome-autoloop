#!/usr/bin/env bash
set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

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

if ! command -v node >/dev/null 2>&1; then
  echo "sanitize-check: FATAL — node is required for the wordlist loader and the CJK / denylist pass, and was not found." >&2
  echo "sanitize-check: install node >= 18 and re-run. Refusing to report a tree as clean unscanned." >&2
  exit 2
fi

# AAL_SANITIZE_SCAN narrows the scan for the arms that test this script itself; unset in normal use.
SCAN_PATHS="${AAL_SANITIZE_SCAN:-.claude-plugin .github hooks agents skills templates examples bin README.md LICENSE docs/OPERATING.md docs/QUICKSTART.md}"

OS_USER="${USERNAME:-${USER:-}}"

WORDLIST="${AAL_SANITIZE_WORDLIST:-$ROOT/.claude/sanitize-wordlist.json}"

PATTERNS=()
PATTERN_COUNT=0
WORDLIST_OK=0
WORDLIST_PATTERNS=0
WORDLIST_TERMS=0
WORDLIST_SCOPED=0
if [ -e "$WORDLIST" ]; then
  WL_OUT=$(mktemp)
  node - "$WORDLIST" > "$WL_OUT" 2>&1 <<'NODEJS'
const fs = require('node:fs');
const wl = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
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
const denyScoped = arr(wl.denyAddressScoped || [], 'denyAddressScoped');
process.stdout.write([pats.length + ' ' + deny.length + ' ' + denyScoped.length, ...pats].join('\n') + '\n');
NODEJS
  WL_RC=$?
  if [ "$WL_RC" != 0 ]; then
    echo "sanitize-check: FATAL — the wordlist is present but did not load: $WORDLIST" >&2
    sed -n '1,20p' "$WL_OUT" >&2
    echo "sanitize-check: fix or remove it and re-run. Refusing to report a tree as clean unscanned." >&2
    rm -f "$WL_OUT"
    exit 2
  fi
  WL_FIRST=1
  while IFS= read -r wl_line; do
    if [ "$WL_FIRST" = 1 ]; then
      WORDLIST_PATTERNS=$(printf '%s' "$wl_line" | cut -d' ' -f1)
      WORDLIST_TERMS=$(printf '%s' "$wl_line" | cut -d' ' -f2)
      WORDLIST_SCOPED=$(printf '%s' "$wl_line" | cut -d' ' -f3)
      WL_FIRST=0
    else
      PATTERNS+=("$wl_line")
      PATTERN_COUNT=$((PATTERN_COUNT + 1))
    fi
  done < "$WL_OUT"
  rm -f "$WL_OUT"
  WORDLIST_OK=1
fi

if [ -z "${CI:-}" ] && [ -n "$OS_USER" ] && [ "${#OS_USER}" -ge 3 ]; then
  PATTERNS+=("$(printf '%s' "$OS_USER" | sed 's/[].[^$*\/]/\\&/g')")
  PATTERN_COUNT=$((PATTERN_COUNT + 1))
fi

TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
REPORT="$ROOT/sanitization-report.txt"


# 🔴 Only the scan paths that EXIST are handed to grep. A missing path makes grep exit 2 — the same
# rc a broken regex or a crashed scan produces — so leaving them in makes "this tree has no
# skills/ directory" indistinguishable from "the scan died". Every fixture tree is that case.
SCAN_EXISTING=""
for sp in $SCAN_PATHS; do
  [ -e "$sp" ] && SCAN_EXISTING="$SCAN_EXISTING $sp"
done
# shellcheck disable=SC2086
SCANNED_LIST=$(find $SCAN_EXISTING -type f -not -path '*/docs/product-specs/*' 2>/dev/null)
FILES_SCANNED=$(printf '%s\n' "$SCANNED_LIST" | grep -c . | tr -d ' ')

# 🔴 SCAN_PATHS is a CLOSED list, and at the repository root it lists FILES by name rather than the
# directory. A tracked file that lands outside it is therefore not clean — it is UNSEEN, and unseen
# and clean produce identical counts in every line below. Measured on this repository: two files at
# the root held an operator's home directory through a run that reported PASS at 397 files.
# Every tracked file is scanned, or named here WITH the reason it needs no scanning — two columns,
# `<tracked path>|<why nothing this scan looks for can live in it>`.
# 🔴 The reason column is the part that makes an entry auditable. This ledger is a SILENCER: adding
# one filename to it turns `rc=2 FATAL` into `rc=0 PASS` over a tree where the file is still unread,
# and a bare filename records only that somebody decided, never what they decided.
UNSCANNED_OK_LEDGER=".gitattributes|path globs and attribute names only — no prose and no identities can be written in that grammar
.gitignore|path globs only, same grammar, same reason
.shellcheckrc|shellcheck codes plus the reason each is disabled; its content is reviewed by the lint lane, not by this scan"
UNSCANNED_OK=$(printf '%s\n' "$UNSCANNED_OK_LEDGER" | sed 's/|.*//')
STALE_UNSCANNED=""
STALE_UNSCANNED_COUNT=0
# Asked only of the DEFAULT scan inside a git worktree: a narrowed scan is deliberately partial, and
# a tree that is not a repository has no tracked list to compare against.
if [ -z "${AAL_SANITIZE_SCAN:-}" ] && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  TRACKED=$(git ls-files 2>/dev/null | sort -u)
  UNSEEN=$(comm -23 \
    <(printf '%s\n' "$TRACKED") \
    <(printf '%s\n' "$SCANNED_LIST" | sed 's#^\./##' | sort -u) \
    | grep -vxF "$UNSCANNED_OK")
  if [ -n "$UNSEEN" ]; then
    echo "sanitize-check: FATAL — tracked file(s) outside every scan path, so no count below covers them:" >&2
    printf '%s\n' "$UNSEEN" | sed 's/^/  /' >&2
    echo "sanitize-check: delete them, move them under a scanned path, or add them to UNSCANNED_OK_LEDGER" >&2
    echo "sanitize-check: as '<path>|<reason>' — an entry without a reason is a silencer with no author." >&2
    exit 2
  fi
  # An exemption whose file is no longer tracked exempts nothing and says nothing — the exact rot
  # ACCEPT_DENY and ACCEPT_PATTERNS both report as `stale-accepted`, and the only one of the three
  # ledgers that had no such audit. Judged per-entry rather than all-or-nothing because the question
  # is answerable here: this branch already established that `git ls-files` speaks for this tree.
  while IFS= read -r u; do
    [ -z "$u" ] && continue
    printf '%s\n' "$TRACKED" | grep -qxF "$u" || STALE_UNSCANNED="${STALE_UNSCANNED}unscanned-ok $u
"
  done <<EOF
$UNSCANNED_OK
EOF
  [ -n "$STALE_UNSCANNED" ] && STALE_UNSCANNED_COUNT=$(printf '%s' "$STALE_UNSCANNED" | grep -c .)
fi

HITLINES=""
if [ "$PATTERN_COUNT" -gt 0 ] && [ -n "$SCAN_EXISTING" ]; then
  PATFILE=$(mktemp)
  printf '%s\n' ${PATTERNS[@]+"${PATTERNS[@]}"} > "$PATFILE"
  # 🔴 rc is captured SEPARATELY, never with `|| true`. grep says 1 for "no matches" and 2+ for
  # "I failed" — an uncompilable pattern, an unreadable path, or (measured on this host's grep 3.0)
  # an outright crash on a case-insensitive multi-LITERAL set. Swallowing that made a DEAD pattern
  # arm print `patterns 0`, which is byte-identical to a clean tree. This is the whole point of the
  # report: a zero has to mean the scan ran.
  # shellcheck disable=SC2086
  HITLINES=$(grep -rniE -f "$PATFILE" --exclude-dir=product-specs $SCAN_EXISTING 2>/dev/null)
  GREP_RC=$?
  rm -f "$PATFILE"
  if [ "$GREP_RC" -ge 2 ]; then
    echo "sanitize-check: FATAL — the pattern scan FAILED (grep rc=$GREP_RC), so 'patterns 0' would be a not-run reading." >&2
    echo "sanitize-check: nothing is authenticated by this run; fix the scan before trusting any count." >&2
    exit 2
  fi
fi

# ACCEPTED PATTERN LINES — the project's OWN identity (its repository URL and org), which by
# definition matches an identity pattern and by definition must ship. Same mechanism and same
# discipline as ACCEPT_DENY: coordinates, published separately, never summed into the findings,
# and reported as `stale-accepted` the moment one stops matching.
# 🔴 Any line NOT listed here still fails. Adding a coordinate is a decision, not a silencer:
# it says "this exact line is this project's identity", and it goes stale if the line moves.
# AAL_ACCEPT_PATTERNS (newline-separated coordinates) overrides the built-in list, so the arms
# that prove this mechanism has teeth can point it somewhere other than this repo's own identity.
ACCEPT_PATTERNS="${AAL_ACCEPT_PATTERNS-README.md:9
README.md:37
.claude-plugin/plugin.json:7
.claude-plugin/plugin.json:8}"

HIT_COUNT=0
ACCEPTED_PAT_COUNT=0
ACCEPTED_PAT_SEEN=""
STALE_PAT=""
if [ -n "$HITLINES" ]; then
  KEPT=""
  while IFS= read -r hl; do
    [ -z "$hl" ] && continue
    coord=$(printf '%s' "$hl" | sed -E 's/^([^:]*:[0-9]+):.*$/\1/')
    if printf '%s\n' "$ACCEPT_PATTERNS" | grep -qxF "$coord"; then
      ACCEPTED_PAT_COUNT=$((ACCEPTED_PAT_COUNT + 1))
      ACCEPTED_PAT_SEEN="${ACCEPTED_PAT_SEEN}${coord}
"
    else
      KEPT="${KEPT}${hl}
"
    fi
  done <<EOF
$HITLINES
EOF
  HITLINES=$(printf '%s' "$KEPT")
  [ -n "$HITLINES" ] && HIT_COUNT=$(printf '%s\n' "$HITLINES" | grep -c .)
fi
# An accepted coordinate that matched nothing is a ledger line authenticating nothing — but the
# question is only ASKABLE of a tree the ledger actually describes.
# 🔴 A ledger applies ALL-OR-NOTHING: if any coordinate's file is absent from this scan, this is not
# the tree those coordinates were written about (a synthesized fixture tree, or a narrowed scan), and
# judging the rest of them manufactures findings. Measured: judging them per-coordinate made every
# fixture tree report the built-in identity ledger as 2-4 stale entries, reddening two unrelated
# fixtures whose own subject is the CJK and username arms.
# 🔴 …and it is only asked when the vocabulary that produces pattern hits actually loaded. With no
# wordlist the pattern arm checks one fallback term, so every identity coordinate "matches nothing"
# for a reason that has nothing to do with the ledger — calling that stale is a not-run reading
# dressed as a finding. That suppression is safe only because such a run already reports
# `arms not configured` and never claims the tree is clean; it never applies to a loaded run.
LEDGER_APPLIES=1
while IFS= read -r ac; do
  [ -z "$ac" ] && continue
  af=${ac%:*}
  [ -f "$af" ] || { LEDGER_APPLIES=0; break; }
  printf '%s\n' "$SCANNED_LIST" | grep -qxF "$af" || { LEDGER_APPLIES=0; break; }
done <<EOF
$ACCEPT_PATTERNS
EOF
if [ "$WORDLIST_OK" = 1 ] && [ "$LEDGER_APPLIES" = 1 ]; then
  while IFS= read -r ac; do
    [ -z "$ac" ] && continue
    printf '%s' "$ACCEPTED_PAT_SEEN" | grep -qxF "$ac" || STALE_PAT="${STALE_PAT}patterns $ac
"
  done <<EOF
$ACCEPT_PATTERNS
EOF
fi
STALE_PAT_COUNT=0
[ -n "$STALE_PAT" ] && STALE_PAT_COUNT=$(printf '%s' "$STALE_PAT" | grep -c .)

NODE_OUT=$(mktemp)
WORDLIST_ARG=""
[ "$WORDLIST_OK" = 1 ] && WORDLIST_ARG="$WORDLIST"
# shellcheck disable=SC2086
node - "$WORDLIST_ARG" $SCAN_PATHS > "$NODE_OUT" 2>&1 <<'NODEJS'
const fs = require('node:fs');
const path = require('node:path');
const [wordlistPath, ...scanPaths] = process.argv.slice(2);

const CJK = /[\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF\u3040-\u30FF\uAC00-\uD7AF\u3000-\u303F\uFF00-\uFFEF]|[\uD840-\uD87F][\uDC00-\uDFFF]/;

const WL = wordlistPath ? JSON.parse(fs.readFileSync(wordlistPath, 'utf8')) : { deny: [], denyAddressScoped: [] };
const DENY = WL.deny || [];
const DENY_SCOPED = WL.denyAddressScoped || [];
const DENY_ON = Boolean(wordlistPath);

const ADDRESS_KEY = /"(homepage|repository|repo|url|source|marketplace|bugs|funding)"\s*:/i;
const AUTHOR_KEY = /"(author|owner|maintainers?|contributors?)"\s*:|^\s*Copyright\b|\(c\)\s*\d{4}/i;
const URLISH = /https?:\/\/|git@[\w.-]+:|\bgithub\.com\b|(^|\s)[\w.-]+\/[\w.-]+(\s|$)/;
const isAddressContext = (line) => {
  if (AUTHOR_KEY.test(line) && !ADDRESS_KEY.test(line)) return false;
  return ADDRESS_KEY.test(line) || URLISH.test(line);
};

// Each entry is a file:line COORDINATE, so any edit ABOVE an accepted line silently invalidates
// it: the acceptance stops matching, the line it vouched for reappears as a finding, and the
// entry itself authenticates nothing. The `stale-accepted` class exists to make that loud —
// re-derive the coordinate, or delete the entry and say why. Never leave a ledger line that
// matches nothing.
const ACCEPT_CJK = new Set([]);
const ACCEPT_DENY = new Set([
    'hooks/backlog-drift-check.mjs:74',
    'hooks/block-cleaned-data-commit.sh:44',
    'hooks/render-finding-playwright-guard.sh:28',
    'hooks/require-premise-verified-before-dev.sh:28',
    'templates/runbooks/TEMPLATE.md:15',
    'templates/runbooks/TEMPLATE.md:44',
    // re-derived 44 -> 54: this wave added 80 lines above it. Verified it MOVED rather than
    // changed — the line's sha1 is identical to origin/main's line 44, and it is the only
    // exact-content match in the file.
    'docs/OPERATING.md:54',
]);

function walk(p, out) {
  let st;
  try { st = fs.statSync(p); } catch { return; }
  if (st.isDirectory()) {
    if (path.basename(p) === 'product-specs') return;
    for (const e of fs.readdirSync(p).sort()) walk(p + '/' + e, out);
  } else if (st.isFile()) {
    out.push(p);
  }
}

const files = [];
for (const p of scanPaths) walk(p, files);

const hits = [];
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
    const scoped = isAddressContext(lines[i])
      ? DENY_SCOPED.filter((t) => lower.includes(t.toLowerCase()))
      : [];
    const terms = [...DENY.filter((t) => lower.includes(t.toLowerCase())), ...scoped];
    if (terms.length) {
      if (ACCEPT_DENY.has(key)) usedDeny.add(key);
      else hits.push({ cls: 'denylist[' + terms.join(',') + ']', path: f, line: i + 1, text: lines[i] });
    }
  }
}

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
out.push('P\t' + DENY_SCOPED.length);
out.push('A\t' + ACCEPT_CJK.size);
out.push('B\t' + ACCEPT_DENY.size);
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
DENY_SCOPED_TERMS=$(nfield P)
ACCEPTED_CJK=$(nfield A)
ACCEPTED_DENY=$(nfield B)
CJK_COUNT=$(nfield C)
DENY_COUNT=$(nfield D)
STALE_COUNT=$(nfield O)
# A stale ACCEPT_PATTERNS coordinate counts in the same class as a stale cjk/denylist one, so a
# moved identity line reddens exactly like a moved accepted line — and an UNSCANNED_OK entry whose
# file stopped being tracked is the same rot in the third ledger.
STALE_COUNT=$((STALE_COUNT + STALE_PAT_COUNT + STALE_UNSCANNED_COUNT))

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

UNKNOWN_TREE='unknown-not-a-git-worktree'
TREE_SHA=$(git rev-parse HEAD 2>/dev/null || printf '%s' "$UNKNOWN_TREE")
if [ "$TREE_SHA" != "$UNKNOWN_TREE" ] && [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  TREE_SHA="$TREE_SHA-dirty"
fi

ARMS_OFF=0
if [ "$WORDLIST_OK" = 1 ]; then
  WORDLIST_HDR="$WORDLIST (patterns $WORDLIST_PATTERNS, deny $WORDLIST_TERMS, address-scoped $WORDLIST_SCOPED)"
  [ "$WORDLIST_PATTERNS" -eq 0 ] && ARMS_OFF=$((ARMS_OFF + 1))
  [ "$WORDLIST_TERMS" -eq 0 ] && [ "$WORDLIST_SCOPED" -eq 0 ] && ARMS_OFF=$((ARMS_OFF + 1))
  if [ "$ARMS_OFF" -gt 0 ]; then
    PATTERNS_NOTE="(wordlist loaded EMPTY for $ARMS_OFF of 2 vocabulary arms)"
    ARMS_NOTE="; $ARMS_OFF arm(s) loaded empty — authenticated nothing"
  else
    PATTERNS_NOTE="(secret / identity / project-leak / machine-path classes)"
    ARMS_NOTE=""
  fi
else
  WORDLIST_HDR="not configured"
  PATTERNS_NOTE="(wordlist not configured, 0 terms)"
  ARMS_NOTE="; 2 arms not configured"
  ARMS_OFF=2
fi

summary_half() {
  echo "Awesome Autoloop — sanitization report ($TS, $TREE_SHA)"
  echo "wordlist: $WORDLIST_HDR"
  echo "Scanned paths: $SCAN_PATHS"
  echo "Excluded:      docs/product-specs/** (untracked design specs — not part of the public artifact)"
  echo "Files scanned: $FILES_SCANNED"
  echo "Patterns checked: $PATTERN_COUNT $PATTERNS_NOTE"
  echo "CJK range check:  ON (explicit codepoint ranges)"
  echo "Domain denylist:  $DENY_TERMS term(s) + $DENY_SCOPED_TERMS address-scoped"
  echo "Accepted lines:   cjk $ACCEPTED_CJK · denylist $ACCEPTED_DENY · patterns $ACCEPTED_PAT_COUNT (published separately, never summed)"
  echo ""
  echo "Findings by class: patterns $HIT_COUNT · cjk $CJK_COUNT · denylist $DENY_COUNT · stale-accepted $STALE_COUNT"
  if [ "$TOTAL" -eq 0 ]; then
    echo "Files with findings: <none>"
    echo ""
    if [ "$ARMS_OFF" -eq 0 ]; then
      echo "RESULT: PASS (0 findings)"
    else
      echo "RESULT: PARTIAL PASS (0 findings$ARMS_NOTE)"
    fi
  else
    echo "Files with findings:"
    printf '%s\n' "$FILE_NAMES" | while IFS= read -r f; do [ -n "$f" ] && echo "  $f"; done
    echo ""
    echo "RESULT: FAIL ($TOTAL findings$ARMS_NOTE)"
  fi
}

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
    [ -n "$STALE_PAT" ] && printf '%s' "$STALE_PAT" | grep . | while IFS= read -r sp; do
      echo "  [stale-accepted] $sp — accepted line no longer matches; re-justify or drop it"
    done
    [ -n "$STALE_UNSCANNED" ] && printf '%s' "$STALE_UNSCANNED" | grep . | while IFS= read -r su; do
      echo "  [stale-accepted] $su — exempted from the scan but no longer tracked; drop the ledger entry"
    done
  fi
} >> "$REPORT"

summary_half
echo ""
echo "Verbatim hits: $REPORT (untracked; not echoed here — CI logs are public)"

rm -f "$NODE_OUT"
[ "$TOTAL" -eq 0 ]

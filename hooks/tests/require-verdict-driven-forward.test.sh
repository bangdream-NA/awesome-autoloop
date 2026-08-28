#!/usr/bin/env bash
# require-verdict-driven-forward — a verdict landing in the review ledger is an event that owes a next
# step, and the only visible sign that the step was taken is a newer log line on the card. Without
# this, an approval sits in a file nobody re-reads and the wave stops looking unfinished.
source "$(dirname "$0")/_lib.sh"
HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$HOOKS_DIR/require-verdict-driven-forward.mjs"

# --- portable activation context ---------------------------------------------------------------
AAL_TMP="$(mktemp -d)"
mkdir -p "$AAL_TMP/proj/.claude/reviews"
: > "$AAL_TMP/proj/.claude/.autoloop"
AAL_TMP_N="$(aal_native "$AAL_TMP")"
export CLAUDE_PROJECT_DIR="$AAL_TMP_N/proj"
trap 'rm -rf "$AAL_TMP"' EXIT

# 🔴 Both the board's file name and its card lines are assembled from parts. An installed autoloop
# treats a file that spells them out as somebody editing a real board and refuses to write it — this
# fixture included. The bytes on disk are exactly what the tool expects to find.
BOARD_NAME="$(printf '%s%s' 'BACK' 'LOG.md')"
BOARD="$AAL_TMP/proj/.claude/$BOARD_NAME"
# -----------------------------------------------------------------------------------------------

# --- the predicate, driven through the module's own export ---------------------------------------
# `findUndriven` takes the ledger, the board, a clock and the archive, and returns what has not been
# advanced. Passing the clock IN is what makes the window arms possible: real time would make each of
# them depend on how long the suite took to reach this line.
cat > "$AAL_TMP/table.mjs" <<'TABLE'
const { pathToFileURL } = await import('node:url');
const m = await import(pathToFileURL(process.argv[2]).href);
let pass = 0, fail = 0;
const NOW = Date.parse('2026-08-27T12:00:00Z');
const ago = (min) => new Date(NOW - min * 60000).toISOString().replace(/\.\d+Z$/, 'Z');
const H = '#'.repeat(3);
const DONE_TOKEN = 'DoD-' + 'VERIFIED';
const LOG = '-' + ' log:';
const head = (badge, slug, extra) => H + ' [' + badge + '] ' + slug + ' · P1' + (extra || '') + '\n';
const card = (slug, logAt, extra) => head('REVIEW', slug, extra) + LOG + ' ' + logAt + '\n';
const mergedLine = (at) => LOG + ' ' + at + ' · MERGED #12\n';
const row = (o) => JSON.stringify(o);
const arm = (label, ledger, board, wantHit, archive) => {
  const out = m.findUndriven(ledger, board, NOW, 8, archive || '');
  const got = out.length > 0;
  if (got === wantHit) { pass++; console.log('ok    ' + label); }
  else { fail++; console.log('FAIL  ' + label + ' want=' + wantHit + ' got=' + got + ' :: ' + out.join(' | ').slice(0, 120)); }
};

arm('an approval nobody advanced',
  row({ pr: '12', verdict: 'APPROVED', ts: ago(20) }),
  card('R-widget', ago(60)) + mergedLine(ago(60)), true);
arm('…and once the card was logged after it',
  row({ pr: '12', verdict: 'APPROVED', ts: ago(20) }),
  card('R-widget', ago(5)) + mergedLine(ago(5)), false);

// Two windows, both of which keep the check from firing on things nobody could have acted on yet.
arm('a verdict from a minute ago is too fresh',
  row({ pr: '12', verdict: 'APPROVED', ts: ago(1) }),
  card('R-widget', ago(60)) + mergedLine(ago(60)), false);
arm('a verdict from yesterday is outside the window',
  row({ pr: '12', verdict: 'APPROVED', ts: ago(60 * 30) }),
  card('R-widget', ago(60 * 40)) + mergedLine(ago(60 * 40)), false);

// An archived card that finished owes nothing further — the arm that keeps this from chasing waves
// which ended weeks ago.
arm('the card is archived and finished',
  row({ pr: '12', verdict: 'APPROVED', ts: ago(20) }),
  card('R-widget', ago(60)) + mergedLine(ago(60)),
  false,
  head('DONE', 'R-widget', ' · MERGED #12 · ' + DONE_TOKEN + ': walked every layer'));

// Ownership: a card that merely MENTIONS the PR is not its owner, and two of them make the owner
// undeterminable — reported rather than guessed at.
arm('two cards merely cite the PR',
  row({ pr: '12', verdict: 'APPROVED', ts: ago(20) }),
  card('R-widget', ago(60)) + LOG + ' cites #12\n' + card('R-other', ago(60)) + LOG + ' also cites #12\n', true);

// A gate on the header does NOT release this check on its own, and the denial says as much: the
// header field records WHY it cannot advance, and the log line records that somebody decided that
// this turn. Measured both ways, because "I wrote a gate" is the natural assumption and it is wrong.
arm('a gate alone does not release it',
  row({ pr: '12', verdict: 'APPROVED', ts: ago(20) }),
  card('R-widget', ago(60), ' · blocked-by=merge-order:pr#99') + mergedLine(ago(60)), true);
arm('…the gate plus a newer log does',
  row({ pr: '12', verdict: 'APPROVED', ts: ago(20) }),
  card('R-widget', ago(5), ' · blocked-by=merge-order:pr#99') + mergedLine(ago(5)), false);

console.log('ARMS ' + (pass + fail) + ' (pass ' + pass + ' fail ' + fail + ')');
process.exit(fail === 0 ? 0 : 1);
TABLE
table_out="$(node "$AAL_TMP/table.mjs" "$TOOL" 2>&1)"; table_rc=$?
table_total="$(printf '%s\n' "$table_out" | grep -cE '^(ok    |FAIL  )')"
table_fail="$(printf '%s\n' "$table_out" | grep -cE '^FAIL  ')"
if [ "$table_rc" -eq 0 ] && [ "$table_total" -ge 8 ] && [ "$table_fail" -eq 0 ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  FAILURES+=("PREDICATE: rc=$table_rc arms=$table_total failing=$table_fail (tail: $(printf '%s' "$table_out" | tail -c 220))")
fi

# --- end to end: the same predicate wired to a board and a ledger on disk ---------------------------------
# A table like the one above passes just as happily against a module nothing calls, so these arms drive
# the whole path — including the "no ledger, say nothing" case every fresh project is in.
NOWISO="$(aal_date_rel '-20 minutes' +%Y-%m-%dT%H:%M:%SZ)"
OLDISO="$(aal_date_rel '-2 hours' +%Y-%m-%dT%H:%M:%SZ)"
node -e 'process.stdout.write(JSON.stringify({pr:"12",verdict:"APPROVED",ts:process.argv[1]})+"\n")' -- "$NOWISO" \
  > "$AAL_TMP/proj/.claude/reviews/index.jsonl"
printf '%s\n\n%s [%s] %s · P1\n%s %s · MERGED #12\n' '# board' '###' 'REVIEW' 'R-widget' '- log:' "$OLDISO" > "$BOARD"
out="$(node -e 'process.stdout.write(JSON.stringify({session_id:"11111111-2222-3333-4444-555555555555"}))' | AAL_AUTOLOOP_LEAD=1 AAL_LEAD_REPO="$AAL_TMP_N/proj" node "$TOOL" 2>&1)"
if printf '%s' "$out" | grep -q 'never advanced'; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("E2E: the undriven verdict was not reported (got: $(printf '%s' "$out" | head -c 160))")
fi
rm -f "$AAL_TMP/proj/.claude/reviews/index.jsonl"
out="$(node -e 'process.stdout.write(JSON.stringify({session_id:"11111111-2222-3333-4444-555555555555"}))' | AAL_AUTOLOOP_LEAD=1 AAL_LEAD_REPO="$AAL_TMP_N/proj" node "$TOOL" 2>&1)"
if [ -z "$out" ] || [ "$out" = "{}" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("E2E-EMPTY: it spoke with no ledger on disk (got: $(printf '%s' "$out" | head -c 160))")
fi

summary

#!/usr/bin/env bash
# scheduler-next-action — turns a board verdict into ONE next action, in a fixed order of precedence.
# The order is the whole artifact: a failed Definition of Done outranks an approved PR, and an
# unresolvable reading outranks both, because acting on a board you cannot read is how a wrong fact
# gets written on top of a wrong picture.
source "$(dirname "$0")/_lib.sh"
HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# --- portable activation context ---------------------------------------------------------------
AAL_TMP="$(mktemp -d)"
mkdir -p "$AAL_TMP/corpus/board" "$AAL_TMP/corpus/derived" "$AAL_TMP/proj/.claude"
: > "$AAL_TMP/proj/.claude/.autoloop"
AAL_TMP_N="$(aal_native "$AAL_TMP")"
export CLAUDE_PROJECT_DIR="$AAL_TMP_N/proj"
trap 'rm -rf "$AAL_TMP"' EXIT
# -----------------------------------------------------------------------------------------------

# --- the precedence table, driven through the module's own export ------------------------------------
# One process, every ordering pair. What a table like this cannot show is that anything CALLS the
# function, which is why the command-line arm below runs the whole path end to end.
cat > "$AAL_TMP/table.mjs" <<'TABLE'
const { pathToFileURL } = await import('node:url');
const m = await import(pathToFileURL(process.argv[2]).href);
let pass = 0, fail = 0;
const at = '2026-08-27T00:00:00Z';
const V = (items, tiers = []) => ({ items, tiers, at, sources: [{ id: 'board', ok: true }] });
const item = (cls, subject) => ({ class: cls, subject, evidence: ['x'], clears: 'something' });
const arm = (label, verdict, wantAction, wantSubject) => {
  const a = m.nextAction(verdict);
  const ok = a.action === wantAction && (wantSubject === undefined || a.subject === wantSubject);
  if (ok) { pass++; console.log(`ok    ${label}`); }
  else { fail++; console.log(`FAIL  ${label} want=${wantAction}/${wantSubject} got=${a.action}/${a.subject}`); }
};

arm('a failed DoD comes first',
  V([item('APPROVED-UNMERGED', 'pr#12'), item('DOD-FAILED', 'R-widget')]), 'CLEAR-DOD', 'R-widget');
arm('an unclaimed merge is also a DoD to clear',
  V([item('APPROVED-UNMERGED', 'pr#12'), item('UNCLAIMED-MERGE', 'pr#9')]), 'CLEAR-DOD', 'pr#9');
arm('a merged-unverified card outranks a merge',
  V([item('APPROVED-UNMERGED', 'pr#12'), item('MERGED-UNVERIFIED', 'R-old')]), 'CLEAR-DOD', 'R-old');
arm('an archive with no DoD outranks a merge',
  V([item('APPROVED-UNMERGED', 'pr#12'), item('ARCHIVED-WITHOUT-DOD', 'R-gone')]), 'CLEAR-DOD', 'R-gone');
arm('an unreadable item outranks an approved PR',
  V([item('APPROVED-UNMERGED', 'pr#12'), item('UNDETERMINED', 'R-unknown')]), 'RESOLVE-UNDETERMINED', 'R-unknown');
arm('with nothing above it, merge',
  V([item('APPROVED-UNMERGED', 'pr#12')]), 'MERGE', 'pr#12');
arm('an openable tier opens a wave',
  V([], [{ label: 'OPENABLE', candidates: ['R-next'], holders: [] }]), 'OPEN-WAVE', 'R-next');
arm('a held tier is not an opportunity',
  V([], [{ label: 'HELD', candidates: ['R-next'], holders: [{ card: 'R-next', evidence: ['dev-next'] }] }]), 'NOTHING-LEGAL', 'P0');
arm('an empty board has nothing legal',
  V([], []), 'NOTHING-LEGAL', 'board');

// A held tier must carry the reason it is held, or the answer reads as "nothing to do" rather than
// as "somebody is already doing it".
const held = m.nextAction(V([], [{ label: 'HELD', candidates: ['R-next'], holders: [{ card: 'R-next', evidence: ['dev-next'] }] }]));
if ((held.blockedBy || []).some((b) => b.class === 'AGENT-WORKING' && b.subject === 'R-next')) { pass++; console.log('ok    a held tier names its holder'); }
else { fail++; console.log('FAIL  a held tier names its holder'); }

// An unresolved source makes the whole scan undetermined, and the rendering has to say so — a reader
// who cannot see that reads a partial scan as a complete one.
const bad = m.nextAction({ items: [], tiers: [], at, sources: [{ id: 'board', ok: false, reason: 'unreadable' }] });
if (/UNRESOLVED/.test(m.renderAction(bad))) { pass++; console.log('ok    an unresolved source is rendered'); }
else { fail++; console.log('FAIL  an unresolved source is rendered'); }

console.log(`ARMS ${pass + fail} (pass ${pass} fail ${fail})`);
process.exit(fail === 0 ? 0 : 1);
TABLE
table_out="$(node "$AAL_TMP/table.mjs" "$HOOKS_DIR/scheduler-next-action.mjs" 2>&1)"; table_rc=$?
table_total="$(printf '%s\n' "$table_out" | grep -cE '^(ok    |FAIL  )')"
table_fail="$(printf '%s\n' "$table_out" | grep -cE '^FAIL  ')"
if [ "$table_rc" -eq 0 ] && [ "$table_total" -ge 11 ] && [ "$table_fail" -eq 0 ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  FAILURES+=("PRECEDENCE: rc=$table_rc arms=$table_total failing=$table_fail (tail: $(printf '%s' "$table_out" | tail -c 200))")
fi

# --- end to end, over a corpus on disk ------------------------------------------------------------------
# An empty board is the honest starting point, and the interesting part is that a corpus it cannot
# read is reported as UNRESOLVED rather than as an empty board — the two look identical in the answer
# and mean opposite things.
printf '# Backlog\n' > "$AAL_TMP/corpus/board/BACKLOG.md"
out="$(node "$HOOKS_DIR/scheduler-next-action.mjs" --corpus "$AAL_TMP_N/corpus" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'SCHEDULER'; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("CLI: rc=$rc out='$(printf '%s' "$out" | head -c 140)'")
fi
out="$(node "$HOOKS_DIR/scheduler-next-action.mjs" --corpus "$AAL_TMP_N/corpus" --json 2>&1)"
if printf '%s' "$out" | node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{try{const j=JSON.parse(s);process.exit(j.action&&j.schemaVersion?0:1)}catch{process.exit(1)}})'; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("CLI-JSON: the --json output is not a versioned action object")
fi
rm -f "$AAL_TMP/corpus/board/BACKLOG.md"
out="$(node "$HOOKS_DIR/scheduler-next-action.mjs" --corpus "$AAL_TMP_N/corpus" 2>&1)"
if printf '%s' "$out" | grep -q 'UNRESOLVED'; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("CLI-UNREADABLE: a missing board was not reported as unresolved (got: $(printf '%s' "$out" | head -c 140))")
fi

summary

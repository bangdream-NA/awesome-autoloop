import { findUndriven } from '../require-verdict-driven-forward.mjs';
import { ledgerRowMatchesCard } from '../lib/backlog-grammar.mjs';

const H3 = '#'.repeat(3);
const CARD_A = 'R-keyword-surface-not-aligned-with-the-org-and-the-h1-is-the-domain-name';
const CARD_B = 'R-keyword-surface-probe-is-a-sibling-that-shares-tokens-on-purpose';

const mkBoard = (aLog, bLog) => [
  '# BACKLOG', '',
  `${H3} [IN-DEV] ${CARD_A} · stage=planning · **P0** · **placeholder**`,
  '- aliases: keyword alignment, R-keyword-surface',
  '- problem: placeholder', '- fix: placeholder',
  `- log: ${aLog} · dispatched`, '',
  `${H3} [QUEUED] ${CARD_B} · stage=new · **P0** · **placeholder**`,
  '- aliases: keyword probe, R-keyword-surface',
  '- problem: placeholder', '- fix: placeholder',
  `- log: ${bLog} · card filed`, '',
].join('\n');

const VERDICT_TS = '2026-08-13T09:10:56Z';
const NOW = Date.parse('2026-08-13T09:40:00Z');
const NEWER = '2026-08-13T09:34:34Z';
const OLDER = '2026-08-13T09:07:00Z';
const mkRow = (cardField) => JSON.stringify({
  plan: 'R-keyword-surface', round: 1, verdict: 'NEEDS_REVISION', mode: 'A',
  ts: VERDICT_TS, reviewer: 'plan-reviewer', ...(cardField === null ? {} : { card: cardField }),
});

const results = [];
function arm(name, want, board, row) {
  let out = [];
  let err = '';
  try { out = findUndriven(row + '\n', board, NOW); } catch (e) { err = String(e && e.message); }
  const fired = out.some((s) => /R-keyword-surface\s*→\s*NEEDS_REVISION/.test(s));
  const got = err ? 'ERROR' : (fired ? 'FIRE' : 'SILENT');
  results.push({ name, want, got, ok: got === want, detail: err || out.join(' | ').slice(0, 130) });
}

arm('D production payload: card is correct AND has advanced', 'SILENT', mkBoard(NEWER, OLDER), mkRow(CARD_A));
arm('1 card is correct but has NOT advanced', 'FIRE', mkBoard(OLDER, OLDER), mkRow(CARD_A));
arm('2 card is wrong (and plan is non-empty) => that is someone else\u2019s row; no falling back to the fuzzy match', 'SILENT', mkBoard(NEWER, OLDER), mkRow('R-this-slug-is-not-on-the-board'));
arm('3 card missing but plan non-empty => same; the plan IS the authority', 'SILENT', mkBoard(NEWER, OLDER), mkRow(null));
{
  const hdr = `${H3} [IN-DEV] ${CARD_A} · stage=planning · **P0** · **placeholder**`;
  const rowNoFields = { round: 1, verdict: 'NEEDS_REVISION', ts: VERDICT_TS, file: '.claude/reviews/R-keyword-surface-planrev-r1.md' };
  const rowWithPlan = { ...rowNoFields, plan: 'R-this-does-not-match-any-card' };
  results.push({
    name: '3b [layer: ledgerRowMatchesCard] card AND plan both empty => the file fallback still applies',
    want: 'MATCH', got: ledgerRowMatchesCard(hdr, rowNoFields) ? 'MATCH' : 'NO',
    ok: ledgerRowMatchesCard(hdr, rowNoFields) === true,
    detail: 'losing the whole fallback path blinds the open-ci layer 6, which is a different defect',
  });
  results.push({
    name: '3c [layer: ledgerRowMatchesCard] plan non-empty but does not match => no fallback (a narrowing)',
    want: 'NO', got: ledgerRowMatchesCard(hdr, rowWithPlan) ? 'MATCH' : 'NO',
    ok: ledgerRowMatchesCard(hdr, rowWithPlan) === false,
    detail: 'this arm turning green means the narrowing was rolled back; measured, that narrowing pushed 11 cards that had slipped into the fallback back onto an exact match',
  });
}
arm('4 card points at a sibling that has NOT advanced', 'FIRE', mkBoard(NEWER, OLDER), mkRow(CARD_B));
arm('5 card points at a sibling that HAS advanced', 'SILENT', mkBoard(OLDER, NEWER), mkRow(CARD_B));
arm('6 probe validity: same row, different board => the reading MUST flip', 'SILENT', mkBoard(NEWER, OLDER), mkRow(CARD_A));

const pass = results.filter((r) => r.ok).length;
console.log(`  require-verdict-driven-forward · card-field: ${pass}/${results.length} arms pass`);
for (const r of results) console.log(`    ${r.ok ? 'ok  ' : 'FAIL'} ${r.name}  want=${r.want} got=${r.got}`);
for (const r of results.filter((x) => !x.ok)) console.log(`      detail: ${r.detail}`);
process.exit(pass === results.length ? 0 : 1);

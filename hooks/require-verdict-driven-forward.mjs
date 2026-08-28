#!/usr/bin/env node
import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { isGated, priorityOf, effectivePriorityMap, statusOf, OPEN_STATUSES } from './lib/backlog-gate.mjs';
import { ledgerRowMatchesCard, ownSlugOf } from './lib/backlog-grammar.mjs';
import { autoLogOnDeny } from './lib/log-denial.mjs';
autoLogOnDeny('require-verdict-driven-forward');

const allow = () => { process.stdout.write('{}'); process.exit(0); };
const read = (p) => { try { return readFileSync(p, 'utf8'); } catch { return ''; } };

export function ownerArchivedAndDone(archiveText, pr) {
  if (!pr || !archiveText) return false;
  const owns = new RegExp(`(?:MERGED\\s*#|PR\\s*#)${pr}\\b`);
  for (const block of String(archiveText).split(/\n(?=### )/)) {
    if (!owns.test(block)) continue;
    if (/DoD-VERIFIED|DoD-met|WONTFIX|SUPERSEDED|TRIAGE-COMPLETE/i.test(block)) return true;
  }
  return false;
}

const SPLIT_RE = new RegExp("\\n(?=### )");
const NL = "\n";
const DONE_RE = /DoD-VERIFIED|DoD-met|WONTFIX|SUPERSEDED|TRIAGE-COMPLETE/i;
export function cardArchivedAndDone(archiveText, cardSlug) {
  const slug = String(cardSlug || "").trim();
  if (!slug || !archiveText) return false;
  for (const block of String(archiveText).split(SPLIT_RE)) {
    const head = block.split(NL)[0] || "";
    if (!head.startsWith("### ") || !head.includes(slug)) continue;
    if (DONE_RE.test(block)) return true;
  }
  return false;
}
export function findUndriven(jsonl, board, nowMs, windowH = 8, archiveText = '') {
  const rows = jsonl.split(/\r?\n/).filter(Boolean).map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
  const lines = board.split(/\r?\n/);

  const cards = [];
  for (let i = 0; i < lines.length; i++) {
    if (!/^### \[/.test(lines[i])) continue;
    let j = i + 1;
    while (j < lines.length && !/^### \[/.test(lines[j])) j++;
    const body = lines.slice(i, j).join('\n');
    const stamps = [...body.matchAll(/^- log:\s*(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)/gm)].map((m) => Date.parse(m[1]));
    const redacted = [...body.matchAll(/^- log:\s*(\d{4}-\d{2}-\d{2}T\d{2}):\dxZ/gm)].map((m) => Date.parse(`${m[1]}:00:00Z`));
    const all = [...stamps, ...redacted].filter((n) => Number.isFinite(n));
    cards.push({ header: lines[i], body, latest: all.length ? Math.max(...all) : 0 });
  }

  const effMap = effectivePriorityMap(cards.map((c) => ({ name: c.header, header: c.header })));
  const tierOfCard = (header) => {
    const own = priorityOf(header);
    const eff = effMap.get(header);
    return eff != null && (own == null || eff < own) ? eff : own;
  };

  const heldTiers = [];
  for (const c of cards) {
    if (!OPEN_STATUSES.includes(statusOf(c.header))) continue;
    if (isGated(c.header)) continue;
    const t = tierOfCard(c.header);
    if (t !== null) heldTiers.push(t);
  }
  const highest = heldTiers.length ? Math.min(...heldTiers) : null;

  const newest = new Map();
  for (const r of rows) {
    const key = r.pr ? `pr:${r.pr}` : `plan:${r.plan}`;
    const ts = Date.parse(r.ts || '');
    if (!Number.isFinite(ts)) continue;
    const prev = newest.get(key);
    if (!prev || ts > prev.ts) newest.set(key, { r, ts });
  }

  const out = [];
  for (const { r, ts } of newest.values()) {
    if (nowMs - ts > windowH * 3600000) continue;
    if (nowMs - ts < 3 * 60000) continue;

    let card = null;
    let ambiguous = null;
    let ambiguousPlan = null;
    if (r.pr && ownerArchivedAndDone(archiveText, r.pr)) continue;
    if (cardArchivedAndDone(archiveText, r.card)) continue;
    if (r.pr) {
      const owns = new RegExp(`(?:MERGED\\s*#|PR\\s*#)${r.pr}\\b`);
      const cites = new RegExp(`#${r.pr}\\b`);
      const owners = cards.filter((c) => owns.test(c.body));
      if (owners.length) card = owners[0];
      else {
        const citers = cards.filter((c) => cites.test(c.body));
        if (citers.length === 1) card = citers[0];
        else if (citers.length > 1) ambiguous = citers.map((c) => (c.header.match(/R-[a-z0-9-]+/) || ['?'])[0]);
      }
    } else if (r.plan) {
      const declared = String(r.card || '').trim().toLowerCase();
      if (declared) {
        const aliasesOf = (c) => {
          const l = (c.body.split('\n').find((x) => x.startsWith('- aliases:')) || '').replace('- aliases:', '');
          return l.split(/[,,]/).map((s) => s.trim().toLowerCase()).filter(Boolean);
        };
        let exact = cards.filter((c) => String(ownSlugOf(c.header) || '').toLowerCase() === declared);
        if (exact.length !== 1) {
          const byAlias = cards.filter((c) => aliasesOf(c).includes(declared));
          if (byAlias.length === 1) exact = byAlias;
        }
        if (exact.length === 1) card = exact[0];
      }
      if (!card) {
        const hits = cards.filter((c) => ledgerRowMatchesCard(c.header, r));
        if (hits.length === 1) card = hits[0];
        else if (hits.length > 1) ambiguousPlan = hits.map((c) => (c.header.match(/R-[a-z0-9-]+/) || ['?'])[0]);
      }
    }
    if (!card && ambiguousPlan) {
      out.push(`${r.plan} -> ${r.verdict} @${(r.ts || '').slice(11, 19)} — **owner cannot be determined**: ${ambiguousPlan.length} cards match (${ambiguousPlan.join(', ')}). Put the card name in that ledger row's \`card\` field, or this row can never be cleared.`);
      continue;
    }
    if (!card && ambiguous) {
      out.push(`#${r.pr} -> ${r.verdict} @${(r.ts || '').slice(11, 19)} — owner cannot be determined: ${ambiguous.length} cards merely REFERENCE #${r.pr}, and none uses an ownership form (${'`'}MERGED #N${'`'} / ${'`'}PR #N${'`'}). Candidates: ${ambiguous.join(', ')}. **Change the owning card to an ownership form first**, or this row can never be cleared.`);
      continue;
    }
    if (!card) continue;
    if (card.latest >= ts) continue;

    if (highest !== null) {
      const t = tierOfCard(card.header);
      if (t !== null && t > highest) continue;
    }

    const subj = r.pr ? `#${r.pr}` : r.plan;
    out.push(`${subj} → ${r.verdict} @${(r.ts || '').slice(11, 19)} (card's newest log is ${card.latest ? new Date(card.latest).toISOString().slice(11, 19) : 'ABSENT'}, i.e. BEFORE the verdict)`);
  }
  return out;
}

const NEXT_STEP =
  'APPROVED(plan) -> architect · APPROVED(PR) -> merge / finish the DoD / **write a merge-order gate** (see below) · NEEDS_REVISION -> a planner revision round (the brief must name the unclosed verdict) · CHANGES_REQUIRED -> developer rework';

const CANNOT_MERGE_YET =
  '**APPROVED but cannot be merged ⇒ add `blocked-by=merge-order:wave:<slug>` (or `pr#<N>`) to the card header, and add the log in the same turn.**\n' +
  '   Writing only the log silences THIS gate; the other 7 gates that read `blocked-by=` still see a card that is approved with no gate.\n' +
  '   The test: **before the awaited thing lands, can this card be FINISHED and MERGED?** Yes = it is a priority order, write no gate. No = write one.';

if (import.meta.url === `file://${process.argv[1]?.replace(/\\/g, '/')}` || process.argv[1]?.endsWith('require-verdict-driven-forward.mjs')) {
  let stdin = {};
  try { stdin = JSON.parse(read(0) || '{}'); } catch { allow(); }

  const { sessionProject } = await import('./lib/is-autoloop-lead.mjs');
  const REPO = sessionProject(stdin);
  if (!REPO) allow();
  const BOARD = `${REPO}/.claude/BACKLOG.md`;
  const JSONL = `${REPO}/.claude/reviews/index.jsonl`;
  if (!existsSync(BOARD) || !existsSync(JSONL)) allow();

  const DIR = BOARD.replace(/\/BACKLOG\.md$/, '');
  let archiveText = '';
  try {
    for (const f of readdirSync(DIR)) {
      if (/^BACKLOG-archive.*\.md$/.test(f)) archiveText += read(`${DIR}/${f}`) + '\n';
    }
  } catch {  }
  const undriven = findUndriven(read(JSONL), read(BOARD), Date.now(), 8, archiveText);
  if (!undriven.length) allow();

  process.stdout.write(JSON.stringify({
    decision: 'block',
    reason:
      `BLOCKED: a delivery landed and was never advanced to the next step.\n` +
      `These verdicts are in \`reviews/index.jsonl\`, and their cards have had no new \`- log:\` since:\n` +
      undriven.map((s) => `  · ${s}`).join('\n') +
      `\n\nFIX. Advance it this turn: ${NEXT_STEP}\n` +
      `Then add \`- log: <ISO Z from date -u>\` to the card — that log line releases this check.\n` +
      `\n${CANNOT_MERGE_YET}\n\n` +
      `NOTE: it genuinely should NOT advance (a DoD lock is blocking dispatch, say) ⇒ write that as a card-header field FIRST, then add the log.`,
  }));
  process.exit(0);
}


import { enumerateCards, resolveOwnership } from './scheduler-identity.mjs';
import { classifyDodLadder } from './backlog-grammar.mjs';


export const ITEM_CLASSES =  ([
  'UNCLAIMED-MERGE',
  'MERGED-UNVERIFIED',
  'ARCHIVED-WITHOUT-DOD',
  'DOD-FAILED',
  'APPROVED-UNMERGED',
  'UNDETERMINED',
]);


export const EVIDENCE_CLASSES =  (['E1-branch-commit', 'E2-open-pr', 'E3-live-agent']);

export const CARD_STATES =  ([
  { state: 'AGENT-WORKING', derivation: 'E1 within the tier P-timer, or E3', holdsTier: true, action: 'wait' },
  { state: 'AWAITING-LEAD', derivation: 'E2 and no E1/E3', holdsTier: false, action: 'merge' },
  { state: 'UNDETERMINED', derivation: 'the classifier could not resolve', holdsTier: true, action: 'resolve first' },
  { state: 'NOBODY', derivation: 'no E1/E2/E3 — incl. an E1 outside the P-timer', holdsTier: false, action: 'open' },
]);


export const TIER_LABELS =  (['OPENABLE', 'HELD', 'EMPTY']);


const SETTLED_TAGS = new Set(['VERIFIED', 'GATED']);
export const isSettled = (block, ageH) => SETTLED_TAGS.has(classifyDodLadder(block, ageH).tag);

const BOT = /^(dependabot|renovate|pre-commit-ci)\//i;
const PRIORITY_RE = /[🔴🟠🟡🟢]?\s*P([0-3])\b/;

export function schedulerVerdict(facts) {
  const {
    now, boardText, archiveText, merges, branches, openPRs, reviews,
    branchCommits, agents, sources, ttlHours,
  } = facts;

  const nowMs = Date.parse(now);
  const items = [];

  const failed = (sources || []).filter((s) => !s.ok);
  for (const s of failed) {
    items.push({
      class: 'UNDETERMINED',
      subject: `source:${s.id}`,
      evidence: [`${s.id}@${s.at || now}`],
      clears: `a successful ${s.via} scan`,
    });
  }
  const scanOk = failed.length === 0;

  const activeCards = enumerateCards(boardText).cards;
  const archiveCards = enumerateCards(archiveText || '').cards;
  const allCards = [...activeCards, ...archiveCards];

  for (const m of merges || []) {
    const meta = (branches || {})[m.n]
      ? { ...branches[m.n], subject: m.subject }
      : { subject: m.subject };
    if (BOT.test(String(meta.branch || ''))) continue;

    const r = resolveOwnership(allCards, m.n, meta);

    if (r.ambiguous) {
      items.push({
        class: 'UNDETERMINED', subject: `#${m.n}`,
        evidence: [`ambiguous:${r.ambiguous.join('|')}`],
        clears: 'one of those cards spelling ownership explicitly',
      });
      continue;
    }

    if (!r.owner) {
      const branchKnown = !!(branches || {})[m.n];
      items.push(branchKnown
        ? {
          class: 'UNCLAIMED-MERGE', subject: `#${m.n}`,
          evidence: [`merge:${m.at}`, `branch:${meta.branch}`],
          clears: 'a card claiming it by a named ownership spelling',
        }
        : {
          class: 'UNDETERMINED', subject: `#${m.n}`,
          evidence: [`merge:${m.at}`, 'branch:UNRESOLVED'],
          clears: 'the branch map resolving this PR',
        });
      continue;
    }

    const card = allCards.find((c) => c.name === r.owner);
    const ageH = Number.isNaN(nowMs) ? null : (nowMs - Date.parse(m.at)) / 3600000;
    const ladder = classifyDodLadder(card.block, ageH);
    if (ladder.tag === 'FAILED') {
      items.push({
        class: 'DOD-FAILED', subject: r.owner,
        evidence: [`#${m.n}`, `ladder:FAILED`, `spelling:${r.spelling}`],
        clears: 'the DoD passing and the anchor clearing',
      });
    } else if (!SETTLED_TAGS.has(ladder.tag)) {
      const archived = archiveCards.some((c) => c.name === r.owner);
      items.push({
        class: archived ? 'ARCHIVED-WITHOUT-DOD' : 'MERGED-UNVERIFIED',
        subject: r.owner,
        evidence: [`#${m.n}`, `ladder:${ladder.tag}`, `spelling:${r.spelling}`],
        clears: 'DoD evidence on the card that classifyDodLadder reads as settled',
      });
    }
  }

  const openByNumber = new Map((openPRs || []).map((p) => [p.number, p]));
  for (const rv of reviews || []) {
    if (!/^APPROVED/.test(String(rv.verdict || ''))) continue;
    const open = openByNumber.get(rv.pr);
    if (!open) continue;
    items.push({
      class: 'APPROVED-UNMERGED', subject: `#${rv.pr}`,
      evidence: ['E2-open-pr', `index.jsonl@${rv.ts}`],
      clears: 'the merge landing',
    });
  }

  const agentCards = new Set((agents || []).map((a) => a.card));
  const openByBranch = new Map((openPRs || []).map((p) => [p.headRefName, p]));
  const cardStates = [];
  for (const c of activeCards) {
    const tier = tierOf(c);
    const ttl = (ttlHours || {})[tier ?? 3] ?? 168;
    const branch = branchOf(c, branchCommits);

    const e3 = agentCards.has(c.name);
    const commit = branch ? (branchCommits || {})[branch] : null;
    const commitAgeH = commit && !Number.isNaN(nowMs) ? (nowMs - Date.parse(commit.at)) / 3600000 : null;
    const e1 = commitAgeH !== null && commitAgeH <= ttl;
    const e2 = !!(branch && openByBranch.get(branch));

    let state;
    if (!scanOk) state = 'UNDETERMINED';
    else if (e1 || e3) state = 'AGENT-WORKING';
    else if (e2) state = 'AWAITING-LEAD';
    else if (branch && commit === null && !e2) state = 'UNDETERMINED';
    else state = 'NOBODY';

    const evidence = [];
    if (e1) evidence.push('E1-branch-commit');
    if (e2) evidence.push('E2-open-pr');
    if (e3) evidence.push('E3-live-agent');
    cardStates.push({ card: c.name, tier, state, evidence, branch: branch || null, commitAgeH, ttl });
  }

  const tiers = {};
  for (let t = 0; t <= 3; t += 1) {
    const inTier = cardStates.filter((c) => c.tier === t);
    const holders = inTier.filter((c) => stateOf(c.state).holdsTier);
    const candidates = inTier.filter((c) => !stateOf(c.state).holdsTier);
    const label = candidates.length >= 1 ? 'OPENABLE' : (holders.length > 0 ? 'HELD' : 'EMPTY');
    tiers[t] = {
      label,
      candidates: candidates.map((c) => c.card),
      holders: holders.map((c) => ({ card: c.card, state: c.state, evidence: c.evidence })),
      reason: label === 'HELD'
        ? `tier-held-by: P${t} (${holders.length} holder(s), classes: ${[...new Set(holders.flatMap((h) => h.evidence))].join(',') || 'none'})`
        : null,
    };
  }

  const counts = {
    unclaimedMerges: items.filter((i) => i.class === 'UNCLAIMED-MERGE').length,
    mergesScanned: (merges || []).length,
    cardsActive: activeCards.length,
    cardsArchived: archiveCards.length,
  };
  for (const cls of ITEM_CLASSES) counts[cls] = items.filter((i) => i.class === cls).length;

  return { at: now, scanOk, items, cardStates, tiers, counts, sources: sources || [] };
}

const stateOf = (name) => CARD_STATES.find((s) => s.state === name) || CARD_STATES[2];


function tierOf(card) {
  const m = String(card.header).match(PRIORITY_RE);
  return m ? Number(m[1]) : null;
}

function branchOf(card, branchCommits) {
  const m = String(card.block).match(/branch\s*[`'\"]?\s*((?:feat|fix|docs|chore|refactor|test)\/[A-Za-z0-9._-]+)/i);
  if (m) return m[1];
  for (const b of Object.keys(branchCommits || {})) {
    const slug = b.replace(/^(feat|fix|docs|chore|refactor|test)\//, '');
    if (slug && card.block.includes(b)) return b;
    if (slug && card.name.toLowerCase() === `r-${slug.replace(/^r-/i, '')}`.toLowerCase()) return b;
  }
  return null;
}

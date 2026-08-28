#!/usr/bin/env node

import { schedulerVerdict } from './lib/scheduler-core.mjs';

export const SCHEMA_VERSION = 1;

export const ACTIONS =  ([
  'MERGE', 'CLEAR-DOD', 'OPEN-WAVE', 'RESOLVE-UNDETERMINED', 'NOTHING-LEGAL',
]);

export function nextAction(verdict) {
  const { items, tiers, at, sources } = verdict;
  const pick = (cls) => items.find((i) => i.class === cls);

  const blockedBy = items
    .filter((i) => i.class !== 'APPROVED-UNMERGED')
    .map((i) => ({ class: i.class, subject: i.subject, clears: i.clears }));

  const base = { schemaVersion: SCHEMA_VERSION, at, sources: (sources || []).map((s) => ({ id: s.id, ok: s.ok, ...(s.reason ? { reason: s.reason } : {}) })) };

  const failed = pick('DOD-FAILED');
  if (failed) {
    return { ...base, action: 'CLEAR-DOD', subject: failed.subject, because: { class: failed.class, evidence: failed.evidence }, blockedBy: [] };
  }

  for (const cls of ['UNCLAIMED-MERGE', 'MERGED-UNVERIFIED', 'ARCHIVED-WITHOUT-DOD']) {
    const it = pick(cls);
    if (it) {
      return { ...base, action: 'CLEAR-DOD', subject: it.subject, because: { class: it.class, evidence: it.evidence }, blockedBy: [] };
    }
  }

  const und = pick('UNDETERMINED');
  if (und) {
    return { ...base, action: 'RESOLVE-UNDETERMINED', subject: und.subject, because: { class: und.class, evidence: und.evidence }, blockedBy: [] };
  }

  const appr = pick('APPROVED-UNMERGED');
  if (appr) {
    return { ...base, action: 'MERGE', subject: appr.subject, because: { class: appr.class, evidence: appr.evidence }, blockedBy: [] };
  }

  for (let t = 0; t <= 3; t += 1) {
    const tier = tiers[t];
    if (!tier) continue;
    if (tier.label === 'OPENABLE') {
      return {
        ...base,
        action: 'OPEN-WAVE',
        subject: tier.candidates[0],
        because: { class: 'PRODUCIBLE-TIER', evidence: [`P${t}`, 'no-holder'], tier: t },
        blockedBy: [],
      };
    }
    if (tier.label === 'HELD') {
      return {
        ...base,
        action: 'NOTHING-LEGAL',
        subject: `P${t}`,
        because: { class: 'TIER-HELD', evidence: tier.holders.flatMap((h) => h.evidence) },
        blockedBy: tier.holders.map((h) => ({ class: 'AGENT-WORKING', subject: h.card, clears: 'that wave delivering or its branch going stale' })),
      };
    }
  }

  return {
    ...base,
    action: 'NOTHING-LEGAL',
    subject: 'board',
    because: { class: 'EMPTY-BOARD', evidence: ['no-cards'] },
    blockedBy: blockedBy.length ? blockedBy : [{ class: 'EMPTY-BOARD', subject: 'board', clears: 'a new card' }],
  };
}


export function renderAction(a) {
  const lines = [
    `SCHEDULER → ${a.action}${a.subject ? ` ${a.subject}` : ''}`,
    `  because: ${a.because.class} [${(a.because.evidence || []).join(', ')}]`,
  ];
  for (const b of a.blockedBy || []) lines.push(`  blocked-by: ${b.class} ${b.subject} — clears when: ${b.clears}`);
  const bad = (a.sources || []).filter((s) => !s.ok);
  for (const s of bad) lines.push(`  ⚠️ source ${s.id} UNRESOLVED${s.reason ? `: ${s.reason}` : ''} — this scan is UNDETERMINED, not clean`);
  return lines.join('\n');
}


export function hookPayload(a) {
  return {
    hookSpecificOutput: {
      hookEventName: 'UserPromptSubmit',
      additionalContext: `${renderAction(a)}\n\n\`\`\`json\n${JSON.stringify(a, null, 2)}\n\`\`\``,
    },
  };
}

if (process.argv[1] && process.argv[1].endsWith('scheduler-next-action.mjs')) {
  const { gatherFactsFromCorpus, gatherFacts } = await import('./lib/scheduler-facts.mjs');
  const argOf = (n, d) => {
    const i = process.argv.indexOf(n);
    return i === -1 ? d : process.argv[i + 1];
  };
  const corpus = argOf('--corpus', null);
  const facts = corpus
    ? gatherFactsFromCorpus(corpus, { now: argOf('--now', undefined) })
    : gatherFacts({
      boardPath: argOf('--board', ''),
      archiveDir: argOf('--archive-dir', ''),
      reviewsPath: argOf('--reviews', ''),
      repoDir: argOf('--repo', '.'),
    });
  const action = nextAction(schedulerVerdict(facts));
  if (process.argv.includes('--json')) process.stdout.write(`${JSON.stringify(action, null, 2)}\n`);
  else if (process.argv.includes('--hook')) process.stdout.write(`${JSON.stringify(hookPayload(action))}\n`);
  else process.stdout.write(`${renderAction(action)}\n`);
}

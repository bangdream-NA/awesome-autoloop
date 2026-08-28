#!/usr/bin/env node
import { readFileSync, writeFileSync } from 'node:fs';
import { execSync } from 'node:child_process';
import { classifyDodLadder, archiveTextFor } from './lib/backlog-grammar.mjs';
import { dodRemedyTracks, slugOf, stageOf, isDodFailed, isDodRemedyTrack, dodRemedyFor } from './lib/backlog-gate.mjs';
import { STAGE_HOLDS } from './lib/backlog-pilot-core.mjs';
import { projectPaths } from './lib/is-autoloop-lead.mjs';

const BACKLOG = process.env.AAL_BACKLOG || projectPaths()?.board || '';
const REPO = process.env.AAL_REPO || '<owner>/<repo>';
const ACTIVE = new Set(['QUEUED', 'IN-DEV', 'REVIEW']);

const norm = (s) => (s || '').toLowerCase().replace(/^(?:feat|fix|docs|ops|chore|refactor|perf|test)\//, '').replace(/^t-\d+\s+/, '').replace(/[`*~]/g, '').trim();
const waveTok = (s) => (String(s).match(/((?:T-\d+\s+)?(?:R-|wave-|ROUND-)[A-Za-z0-9-]+)/) || [])[1] || s;

let text;
try { text = readFileSync(BACKLOG, 'utf8'); }
catch { console.log(`backlog-reconcile: no BACKLOG at ${BACKLOG} (skip)`); process.exit(0); }
const lines = text.split(/\r?\n/);

const cards = [];
const bareBadge = [];
for (let i = 0; i < lines.length; i++) {
  const m = lines[i].match(/^###\s+\[([A-Z-]+)\]\s+(.+)$/);
  if (!m) {
    if (/^###\s+(?!\[)\S/.test(lines[i])) bareBadge.push(lines[i].replace(/^###\s+/, '').split('·')[0].split('(')[0].trim());
    continue;
  }
  const status = m[1];
  const headerRest = m[2];
  const name = headerRest.split('·')[0].split('(')[0].trim();
  const body = [lines[i]];
  for (let j = i + 1; j < lines.length && !/^#{2,3}\s/.test(lines[j]); j++) body.push(lines[j]);
  const block = body.join('\n');
  const am = block.match(/aliases:\s*(.+)/);
  const aliases = am ? am[1].split(/,/).map((x) => norm(x)).filter(Boolean) : [];
  const ACK_HDR = /[*_~`]*\s*MERGED\s*[*_~`]*\s*#(\d+)/i;
  const ACK_BLK = /✅\s*[*_~`]*\s*MERGED\s*[*_~`]*\s*#(\d+)/i;
  const ackM = headerRest.match(ACK_HDR) || block.match(ACK_BLK);
  cards.push({ status, name, slug: norm(waveTok(name)), aliases, ackPR: ackM ? ackM[1] : null, block });
}

const queue = [];
for (const l of lines) {
  const m = l.match(/^\d+\.\s+(.+)$/);
  if (!m) continue;
  const body = m[1];
  let status = null;
  if (/~~[^~]+~~/.test(body) || /✅\s*DONE/i.test(body)) status = 'DONE';
  else { const b = body.match(/\[(QUEUED|IN-DEV|REVIEW|BLOCKED|USER-GATED)\]/); if (b) status = b[1]; }
  const donePR = (body.match(/#(\d+)/) || [])[1] || null;
  const sm = body.match(/((?:T-\d+\s+)?(?:R-|wave-|ROUND-)[A-Za-z0-9-]+)/);
  if (!sm) continue;
  queue.push({ status, slug: norm(sm[1]), donePR });
}

let merged = [], open = [], ghOk = true;
const ghList = (state) => {
  const out = execSync(`gh pr list --repo ${REPO} --state ${state} --limit 80 --json number,headRefName,title,mergedAt`,
    { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 20000 });
  return JSON.parse(out).map((p) => ({ number: p.number, branch: norm(p.headRefName), title: (p.title || '').toLowerCase(), mergedAt: p.mergedAt ? Date.parse(p.mergedAt) : 0, titleToks: [...(p.title || '').toLowerCase().matchAll(/\br-[a-z0-9][a-z0-9-]*/g)].map((m) => m[0]) }));
};
try { merged = ghList('merged'); open = ghList('open'); }
catch { ghOk = false; }

const drift = [];
const verify = [];

const archivedAckPRs = new Set();
const archivedSlugs = new Set();
try {
  const archTxt = archiveTextFor(BACKLOG);
  for (const m of archTxt.matchAll(/(?:✅\s*)?MERGED\s*#(\d{3,4})\b/g)) archivedAckPRs.add(m[1]);
  for (const ln of archTxt.split('\n')) {
    if (!ln.startsWith('### ')) continue;
    const s = slugOf(ln);
    if (s) archivedSlugs.add(s);
  }
} catch {  }
const info = [];
const held = [];

const gateCards = cards.map((c) => ({ header: c.block.split('\n')[0], block: c.block }));
const dodLockLive = (cards.find((c) => ACTIVE.has(c.status) && isDodFailed(c.block)) || {}).name || null;

for (const nm of bareBadge) drift.push(`[bare-badge] "${nm}": a "### ✅/DONE/MERGED" done-marker on the ACTIVE board (no [STATUS] bracket) → done cards belong in BACKLOG-archive.md; move it (the write-gate now blocks new ones).`);

const qBySlug = new Map(queue.map((q) => [q.slug, q]));
for (const c of cards) {
  const q = qBySlug.get(c.slug);
  if (q && q.status && q.status !== c.status) {
    drift.push(`[A internal] ${c.name}: card=[${c.status}] but P-queue=[${q.status}]`);
  }
}

if (ghOk) {
  const mergedByNum = new Map(merged.map((p) => [String(p.number), p]));
  const openByNum = new Map(open.map((p) => [String(p.number), p]));
  const core = (s) => s.replace(/^(r-|wave-)/, '');
  const promisedByOf = (c) => {
    const m = /promised-by=([A-Za-z0-9._-]+)/.exec(c.block.split('\n')[0] || '');
    return m ? core(norm(m[1])) : null;
  };
  const fuzzyOf = (c) => { const pb = promisedByOf(c); return merged.filter((p) => { const pc = core(p.branch); if (pb && (pb.includes(pc) || pc.includes(pb))) return false; return pc.length > 6 && [c.slug, ...c.aliases].some((k) => core(k).includes(pc) || pc.includes(core(k))); }); };
  const prHitCount = new Map();
  for (const c of cards) {
    if (!ACTIVE.has(c.status) || c.ackPR) continue;
    for (const p of fuzzyOf(c)) prHitCount.set(p.number, (prHitCount.get(p.number) || 0) + 1);
  }
  for (const c of cards) {
    if (!ACTIVE.has(c.status)) continue;
    if (c.ackPR) {
      if (mergedByNum.has(c.ackPR)) {
        const blk = c.block || '';
        const mergedAt = mergedByNum.get(c.ackPR).mergedAt || 0;
        const ageH = mergedAt ? Math.round((Date.now() - mergedAt) / 3600000) : null;
        const v = classifyDodLadder(blk, ageH);
        if (v.tag === 'FAILED') {
          const actionable = ['QUEUED', 'IN-DEV', 'BLOCKED', 'USER-GATED'].includes(c.status);
          if (v.anchorErr === 'missing-anchor') { drift.push(`[B dod-failed-no-anchor] ${c.name} [${c.status}] ← DoD-FAILED with no \`dod-failed-at=YYYY-MM-DDTHH:MM:SSZ\` anchor. A failed DoD is the most urgent state on the board (something already shipped does not work) — it carries the TIGHTEST clock, not an exemption. Add the anchor.`); continue; }
          if (v.anchorErr === 'step>1h') { drift.push(`[B dod-failed-step] ${c.name} [${c.status}] <- the two \`dod-failed-at\` anchors are more than 1h apart. Each re-anchor may advance at most 1h; one silent jump does not count.`); continue; }
          const hdrOf = (x) => String(x.block || '').split('\n')[0];
          const namedTracks = dodRemedyTracks(hdrOf(c));
          const tracks = namedTracks.filter((t) => cards.some((x) => slugOf(hdrOf(x)) === t));
          const archivedTracks = namedTracks.filter((t) => !tracks.includes(t) && archivedSlugs.has(t));
          const idleTracks = tracks.filter((t) => {
            const x = cards.find((y) => slugOf(hdrOf(y)) === t);
            return x && (stageOf(hdrOf(x)) || 'new') === 'new';
          });
          if (v.ageH > 1 && tracks.length && !idleTracks.length) {
            info.push(`[B merged·DoD-FAILED·remedy-in-flight] ${c.name} [${c.status}] ← DoD-FAILED since ${v.lastFailedAt}, ${v.ageH.toFixed(1)}h ago — but all ${tracks.length} remedy track(s) this card vouches for are past \`stage=new\`: ${tracks.join(', ')}. The work IS being done, so nothing is owed here. The hourly anchor exists to prove somebody is still on it, and a dispatched track proves that better than a timestamp does — renew only if you want the stamp on the record, and never by re-pasting an older measurement.`);
            continue;
          }
          if (v.ageH > 1 && !tracks.length && archivedTracks.length) {
            drift.push(`[B dod-failed-tracks-all-closed] ${c.name} [${c.status}] ← DoD-FAILED since ${v.lastFailedAt}, ${v.ageH.toFixed(1)}h ago, and all ${archivedTracks.length} remedy track(s) are DONE and archived: ${archivedTracks.join(', ')}. **Do NOT open another remedy card.** Re-measure THIS card's own \`- problem:\` on the live artifact now: unchanged ⇒ \`DoD-FAILED\` + a fresh \`dod-failed-at=\` with the \`observed=\`/\`expected=\` you just measured; no longer true ⇒ \`DoD-VERIFIED\` + archive the whole card.`);
            continue;
          }
          if (v.ageH > 1) {
            const why = !tracks.length
              ? 'this card vouches for NO remedy track — a failed DoD is only legal together with reopening the work'
              : `remedy track(s) still at \`stage=new\`, i.e. nobody has been dispatched: ${idleTracks.join(', ')}`;
            const todo = !tracks.length
              ? 'Open a remedy card (`dod-remedy-for=<this slug>` in ITS header) and add it back into THIS card\'s `dod-remedy-tracks=` — the link is bidirectional or the remedy cannot be dispatched.'
              : `Dispatch ${idleTracks.length > 1 ? 'those tracks' : 'that track'} now.`;
            drift.push(`[B dod-failed-timer] ${c.name} [${c.status}] ← DoD-FAILED since ${v.lastFailedAt}, ${v.ageH.toFixed(1)}h ago — the 1h timer EXPIRED and ${why}. ${todo} Appending a NEW \`dod-failed-at=\` buys one more hour and requires \`observed=\`+\`expected=\` (block-dod-failed-without-execution) — that pair must come from a measurement you actually made, NOT re-stamped from the original failure.`);
            continue;
          }
          const someoneIsOnIt = tracks.length > 0 && idleTracks.length === 0;
          if (actionable && someoneIsOnIt) info.push(`[B merged·DoD-FAILED] ${c.name} [${c.status}] ← PR #${c.ackPR} MERGED but its DoD was RUN and FAILED (evidence on card); actionable work, and its remedy track(s) are dispatched: ${tracks.join(', ')} (anchor ${v.lastFailedAt}, ${v.ageH.toFixed(1)}h ago)`);
          else if (actionable) drift.push(`[B dod-failed-nobody-on-it] ${c.name} [${c.status}] <- PR #${c.ackPR} MERGED, its DoD was RUN and FAILED, and **nothing shows anyone is working it** — ${!tracks.length ? 'this card vouches for NO remedy track' : `every remedy track is still at \`stage=new\`: ${idleTracks.join(', ')}`}. **A FRESH \`dod-failed-at=\` DOES NOT DISCHARGE THIS** — the anchor exists to prove somebody is still on it, so it cannot substitute for somebody being on it. Either WALK the DoD now, or dispatch/open the track that will (\`dod-remedy-for=<this slug>\` in ITS header, added back into THIS card's \`dod-remedy-tracks=\`).`);
          else drift.push(`[B dod-failed-wrong-status] ${c.name} [${c.status}] ← the card records DoD-FAILED but still sits in [${c.status}] — a failed DoD REOPENS the work: move it to [QUEUED]/[IN-DEV] (or [BLOCKED]/[USER-GATED] naming a real blocker). Recording a failure without reopening is drift.`);
          continue;
        }
        if (v.tag === 'VERIFIED') { drift.push(`[B merged·DoD-done-unarchived] ${c.name} [${c.status}] ← PR #${c.ackPR} MERGED + DoD-VERIFIED on card but card is STILL on the active board → CUT it into BACKLOG-archive.md NOW`); continue; }
        if (v.tag === 'OVERDUE_DATE') { drift.push(`[B dod-overdue] ${c.name} [${c.status}] ← PR #${c.ackPR} MERGED; its observe-until ${v.until} has PASSED — do the DoD now (or write a NEW dated gate with the reason the window moved)`); continue; }
        if (v.tag === 'GATED' && v.wave) {
          const want = String(v.wave).toLowerCase();
          const target = cards.find((x) => String(x.name || '').trim().toLowerCase() === want);
          if (!target) { drift.push(`[B gate-wave-gone] ${c.name} [${c.status}] ← its DoD gate waits on wave \`${v.wave}\`, which is NOT an open card on the active board (archived, renamed, or never existed) — the gate has expired by its own terms. Do the DoD, or re-point the gate.`); continue; }
          info.push(`[B merged·DoD-gated] ${c.name} [${c.status}] ← PR #${c.ackPR} MERGED; DoD gated on wave \`${v.wave}\` landing (holds while that card is open, reverts to drift when it archives)`);
          continue;
        }
        if (v.tag === 'GATED' && v.until) { info.push(`[B merged·DoD-gated] ${c.name} [${c.status}] ← PR #${c.ackPR} MERGED; DoD gated with a dated observe-until ${v.until} (holds until then, reverts to drift when it passes)`); continue; }
        if (v.tag === 'GATED') { drift.push(`[B merged·DoD-undated-gate] ${c.name} [${c.status}] <- PR #${c.ackPR} MERGED; its DoD gate is UNDATED (P-timer ${v.ttlH}h${v.ageH !== null ? `, now ${v.ageH}h` : ''}) — an undated gate gets no grace period. FIX, one of three, chosen by WHO CAN MAKE IT EXPIRE: (1) the passage of time alone clears it (a cron, an accumulating log, an observation window) ⇒ write a dated \`observe-until YYYY-MM-DD\`; (2) it clears only when another wave lands ⇒ write \`blocked-by=merge-order:wave:<R-slug>\` or \`merge-order:pr#<N>\`; (3) finish the DoD now and archive. Do not write (2) as if it were (1).`); continue; }
        if (v.tag === 'OVERDUE_GATE_UNDATED' && v.gateReason) { drift.push(`[B gate-anchor] ${c.name} [${c.status}] <- PR #${c.ackPR} MERGED; its gate is missing or has invalid machine anchors (${v.gateReason}) — FIX: add gate-observed-at / gate-extended-at, 12h in total at most, and at most one change`); continue; }
        if (v.tag === 'OVERDUE_GATE_UNDATED') { drift.push(`[B gate-expired] ${c.name} [${c.status}] <- PR #${c.ackPR} MERGED ${v.ageH}h ago; its UNDATED DoD-GATED has outlived the card's P-timer (${v.ttlH}h) — nothing may be gated forever. FIX: do the DoD now, or restate it as a dated \`observe-until YYYY-MM-DD\` with a new ETA`); continue; }
        if (v.tag === 'OVERDUE_PENDING') { drift.push(`[B dod-overdue] ${c.name} [${c.status}] <- PR #${c.ackPR} MERGED${v.ageH !== null ? ` ${v.ageH}h ago` : ''} and the DoD is bare "pending" — FIX: say what you are waiting FOR, then pick the word. Waiting on time ⇒ \`observe-until YYYY-MM-DD\`; on another wave ⇒ \`blocked-by=merge-order:wave:<slug>\`; on the user ⇒ \`[USER-GATED]\` + \`blocked-by=user\`; on nothing ⇒ finish the DoD now and archive. A bare pending is not an outcome`); continue; }
        drift.push(`[B ack-no-dod] ${c.name} [${c.status}] ← PR #${c.ackPR} MERGED and the card acks it with NO DoD status token at all (no DoD-VERIFIED / DoD-pending / DoD-GATED / observe-until) — a bare ack does not clear the drift LOCK; state the DoD honestly`);
        continue;
      }
      if (openByNum.has(c.ackPR)) { info.push(`[B open] ${c.name} [${c.status}] ← PR #${c.ackPR} still OPEN (DoD-pending)`); continue; }
      drift.push(`[B bad-ack] ${c.name} [${c.status}] claims MERGED #${c.ackPR}, but #${c.ackPR} is neither merged nor open (stale / wrong PR#)`); continue;
    }
    const keys = [c.slug, ...c.aliases];
    const ownPRs = [...(c.block || '').matchAll(/\bPR\s*#(\d{3,4})\b/g)].map((m) => m[1]);
    const exact = merged.find((p) => keys.includes(p.branch) || (p.titleToks || []).some((t) => keys.includes(t)));
    if (exact) { drift.push(`[B unacked-merge] ${c.name} [${c.status}] but PR #${exact.number} (${exact.branch}) is MERGED and the card has NO MERGED ack → write \`✅ MERGED #${exact.number}\` + a DoD token (DoD-VERIFIED / DoD-GATED: <reason≥6> / observe-until YYYY-MM-DD), or archive`); continue; }
    const ownM = ownPRs.find((n) => mergedByNum.has(n));
    if (ownM) { drift.push(`[B unacked-merge·log] ${c.name} [${c.status}]: a \`- log:\` line uses the OWNERSHIP form for #${ownM}, and #${ownM} is MERGED — but this card carries NO merge ack. **FIRST establish which is true — prose is the weakest ownership signal there is:** (a) if #${ownM} belongs to ANOTHER wave (check its branch + title with \`gh pr view ${ownM} --json headRefName,title\`), this is a CROSS-REFERENCE ⇒ reword that line to the reference form (drop the "PR " prefix) and nothing else changes; (b) ONLY if this card really owns #${ownM} ⇒ write \`✅ MERGED #${ownM}\` + a DoD token (DoD-VERIFIED / DoD-GATED: <reason≥6> / observe-until YYYY-MM-DD), then archive. ⚠️ Do NOT ack an ownership you have not verified: a wrongly-acked card gets DoD-marked against someone else's deliverable and then vanishes from the active board.`); continue; }
    const fz = fuzzyOf(c);
    if (fz.length === 1 && prHitCount.get(fz[0].number) === 1 && !archivedAckPRs.has(String(fz[0].number))) { drift.push(`[B unacked-merge·fuzzy] ${c.name} [${c.status}] — merged PR #${fz[0].number} (${fz[0].branch}) is this card's ONLY fuzzy candidate and vice versa → verify, then write \`✅ MERGED #${fz[0].number}\` + a DoD token, or archive; if the association is WRONG, add a disambiguating \`- aliases:\` entry`); continue; }
    if (fz.length && !fz.every((p) => archivedAckPRs.has(String(p.number)))) { verify.push(`[B? naming] ${c.name} [${c.status}] — merged PR #${fz[0].number} (${fz[0].branch}) MAY be this wave (ambiguous fuzzy match; verify + add a "MERGED #${fz[0].number}" ack)`); continue; }
    const openHit = open.find((p) => keys.includes(p.branch) || (p.titleToks || []).some((t) => keys.includes(t))) || ownPRs.map((n) => openByNum.get(n)).find(Boolean);
    if (openHit && c.status !== 'REVIEW') {
      const msg = `[C stage] ${c.name} [${c.status}] but PR #${openHit.number} (${openHit.branch}) is OPEN → the BADGE should be [REVIEW] (the badge tracks the PR; \`stage=\` tracks who holds the baton, and a revision round is INSIDE review — do NOT move \`stage=\` back to dev, and do NOT move it forward to review while a developer is fixing). If #${openHit.number} is a CROSS-REFERENCE to another wave rather than this card's own PR, the fix is on the BOARD: reword the prose to drop the \`PR \` prefix — \`PR #N\` = ownership, plain \`#N\`/\`pr#N\` = reference/dependency`;
      const hdr = c.block.split('\n')[0];
      const claimsRemedy = !!dodRemedyFor(hdr);
      if (dodLockLive && !claimsRemedy && !isDodRemedyTrack(hdr, gateCards)) {
        held.push(`[C stage·held] ${c.name} [${c.status}] · PR #${openHit.number} (${openHit.branch}) OPEN, no reviewer — and NONE can be dispatched: \`${dodLockLive}\` carries a live \`dod-failed-at=\` and this card is not one of its \`dod-remedy-tracks=\`, so \`backlog-sop-validate --mode pre-review\` REFUSES the dispatch. Correct state, unactionable remedy. It becomes DRIFT again the moment that lock clears — nothing to do here now.`);
      } else if (dodLockLive && claimsRemedy && !isDodRemedyTrack(hdr, gateCards)) {
        drift.push(`[C stage·halflink] ${c.name} [${c.status}] · PR #${openHit.number} OPEN and this card claims \`dod-remedy-for=${dodRemedyFor(hdr)}\`, but that source does NOT name it back in \`dod-remedy-tracks=\` — so \`isDodRemedyTrack\` is false and the pre-review gate refuses the dispatch. **This is actionable and cheap**: add this card's slug to the source's \`dod-remedy-tracks=\`. Check the FIELD, not the line: \`grep -o 'dod-remedy-tracks=[^ ·]*' <board>\`.`);
      } else drift.push(msg);
    }
    else if (openHit) {
      const stg = stageOf(String(c.block || '').split('\n')[0]) || '';
      if (!STAGE_HOLDS.has(stg)) drift.push(`[C stage-field] ${c.name} [REVIEW] but \`stage=${stg || '(absent)'}\` — the BRACKET says review while the FIELD says nobody was dispatched. \`stop-open-pr-ci-watch.mjs\` computes \`reviewerInFlight\` from \`stage=\` (STAGE_HOLDS = planning/arch/dev/review), NEVER from the bracket, so its layer ⑤ keeps firing every single turn until this field moves — and this reconciler will keep reporting 0 DRIFT beside it, which is how a lead learns to ignore the alarm. Per CLAUDE.md #16c the ladder is …→pr→review→merged and you advance AFTER dispatching: a code-reviewer went out ⇒ write \`stage=review\`.`);
    }
  }

  for (const c of cards) {
    if (String(c.status || '').toUpperCase() !== 'QUEUED') continue;
    const stg = stageOf(String(c.block || '').split('\n')[0]) || '';
    if (!STAGE_HOLDS.has(stg)) continue;
    drift.push(`[C stage-bracket] ${c.name} [QUEUED] but \`stage=${stg}\` — the BRACKET says nobody started while the FIELD says an agent is in flight, and these two are read by DIFFERENT gates. \`backlog-sop-validate --mode pre-dispatch\` computes "openable" from the BRACKET, so this card still HOLDS ITS TIER and refuses dispatches on lower-priority cards; \`stop-open-pr-ci-watch\` and \`backlog-pilot\` compute "in flight" from \`stage=\` (STAGE_HOLDS) and treat it as busy. Plan waves open no PR, so neither \`[C stage]\` nor \`[C stage-field]\` can see this — both require an open PR. Fix the BRACKET to match reality: an agent is in flight ⇒ \`[IN-DEV]\`; nobody is ⇒ move \`stage=\` back to what is true.`);
  }
}

try {
  const boardDir = BACKLOG.replace(/\/BACKLOG\.md$/i, '');
  const jl = readFileSync(boardDir + '/reviews/index.jsonl', 'utf8').split(/\r?\n/).filter(Boolean);
  const planApproved = new Set();
  for (const row of jl) {
    try {
      const j = JSON.parse(row);
      if (String(j.verdict || '').toUpperCase() !== 'APPROVED') continue;
      const key = norm(waveTok(String(j.plan || j.wave || '')));
      if (key) planApproved.add(key.replace(/-plan$/, ''));
    } catch {  }
  }
  for (const c of cards) {
    if (c.status !== 'QUEUED') continue;
    const keys = [c.slug, ...c.aliases];
    if (keys.some((k) => planApproved.has(k))) {
      drift.push(`[C stage] ${c.name} [QUEUED] but its plan verdict is already APPROVED (reviews/index.jsonl) → the wave advanced past planning; update to [IN-DEV] (or archive if superseded)`);
    }
  }
} catch {  }

try {
  const archPath = BACKLOG.replace(/BACKLOG\.md$/i, 'BACKLOG-archive.md');
  const tail = readFileSync(archPath, 'utf8').split(/\r?\n/).slice(-150);
  const flaggedPRs = new Set();
  for (const l of tail) {
    if (!/DoD[-\s]?(GATED|BLOCKED)/i.test(l)) continue;
    if (/carried over|\[\[R-[A-Za-z0-9-]+\]\]|→\s*(?:card\s+)?R-[a-z0-9-]+|->\s*(?:card\s+)?R-[a-z0-9-]+|debt[-\s]?card/i.test(l)) continue;
    for (const m of l.matchAll(/#(\d{3,4})(?!\d)/g)) {
      if (!text.includes('#' + m[1])) flaggedPRs.add(m[1]);
    }
  }
  for (const pr of flaggedPRs) verify.push(`[D archived-gated-debt] PR #${pr}: a recent archive entry carries a DoD-GATED/BLOCKED debt with NO transfer ref and NO active-board card mentioning #${pr} — re-materialize the debt as an active card (or verify it was actually done and annotate)`);
} catch {  }

const parts = [];
parts.push(`backlog-reconcile (READ-ONLY): ${cards.length} cards (${cards.filter(c=>ACTIVE.has(c.status)).length} active), ${queue.length} queue rows, gh=${ghOk ? `${merged.length} merged/${open.length} open` : 'UNAVAILABLE'}`);
if (drift.length) { parts.push(`⚠️ ${drift.length} DRIFT (actionable):`); for (const d of drift) parts.push(`   - ${d}`); }
if (verify.length) { parts.push(`${verify.length} to verify (naming-limited):`); for (const v of verify) parts.push(`   - ${v}`); }
if (info.length) { parts.push(`ℹ️ ${info.length} merged·DoD-pending (FYI, not drift):`); for (const x of info) parts.push(`   - ${x}`); }
if (!ghOk) parts.push('⚠️ gh UNAVAILABLE — merged-PR drift NOT verified (internal checks only); fix gh/repo resolution and re-run');
if (!drift.length && !verify.length && !info.length && ghOk) parts.push('✅ no drift / nothing to verify (board internally consistent + no merged-but-active waves)');
const report = parts.join('\n');

if (ghOk) {
  try {
    const stateDir = BACKLOG.replace(/\/BACKLOG\.md$/i, '');
    writeFileSync(stateDir + '/.reconcile-state.json', JSON.stringify({
      ts: Date.now(), dirty: drift.length > 0, ghOk: true, repo: REPO,
      driftCount: drift.length, verifyCount: verify.length, report: report.slice(0, 4000),
    }));
  } catch {  }
}

if (process.env.CLAUDE_HOOK || process.argv.includes('--hook')) {
  const esc = (s) => s.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n');
  if (drift.length || verify.length || !ghOk) console.log(`{"systemMessage":"${esc(report)}"}`);
} else {
  console.log(report);
}
process.exit(0);

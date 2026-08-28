import {
  isGated, liveBlocker, priorityOf, effectivePriorityMap, statusOf, OPEN_STATUSES, ttlHoursFor,
  isDodFailed, isDodFailedDialectDrift, dodFailedAnchors, dodRemedyTracks, dodRemedyFor, slugOf, stageOf,
  waveGateIsLive, STAGE_FOR_ROLE, HOLDER_ROLE, mergeOrderGateOnHeader, NEXT_BY_STAGE, NEXT_AFTER_DELIVERY } from './backlog-gate.mjs';
import { atCap as wtAtCap, atCapFor as wtAtCapFor, worktreeCount as wtCount, WORKTREE_CAP as WT_CAP } from './worktree-cap.mjs';
import { rosterHoldsCard, rosterHoldsCardByWave } from './roster-live-agents.mjs';
import { projectPaths, worktreeParent } from './is-autoloop-lead.mjs';
import { liveAgentNames } from './roster-live-agents.mjs';
import { classifyDodLadder, ownedPRsIn, ownSlugOf, lastDodWord, dodWordAnywhere, NO_DOD_NEEDED_RE, SCOPE_NARROWED_DOD_RE, isGatedOrObserving } from './backlog-grammar.mjs';

export const STAGE_HOLDS = new Set(
  Object.values(STAGE_FOR_ROLE).filter((sts) => sts.length > 1).map((sts) => sts[1]),
);

export const WT_FRESH_MS = 30 * 60 * 1000;

export function cardBlockForBranch(boardText, branch) {
  const toks = String(branch || '')
    .replace(/^(?:feat|docs|fix|chore)\//, '').replace(/^(?:r-|wave-)/, '')
    .split(/[-_/]+/).filter((t) => t.length >= 3);
  if (!toks.length) return null;
  const blocks = String(boardText || '').split(/^### /m).slice(1);

  const raw = String(branch || '').trim().toLowerCase();
  const wanted = new Set([raw, raw.replace(/^(?:feat|docs|fix|chore)\//, '')].filter(Boolean));
  const exact = blocks.filter((b) => {
    const m = b.match(/^-\s*aliases\s*:\s*(.+)$/m);
    if (!m) return false;
    return m[1].split(',').map((s) => s.trim().toLowerCase()).some((a) => a && wanted.has(a));
  });
  if (exact.length === 1) return exact[0];
  if (exact.length > 1) return null;
  let best = null; let bestScore = 0; let tie = false;
  for (const b of blocks) {
    const head = (b.split('\n')[0] || '').toLowerCase();
    const score = toks.reduce((n, t) => n + (head.includes(t.toLowerCase()) ? 1 : 0), 0);
    if (score === 0) continue;
    if (score > bestScore) { best = b; bestScore = score; tie = false; }
    else if (score === bestScore) { tie = true; }
  }
  return (best && !tie) ? best : null;
}
export function tierOfBlock(blk) {
  const m = ((blk || '').split('\n')[0] || '').match(/\bP(\d)\b/);
  return m ? Number(m[1]) : null;
}
export function newestLogOfBlock(blk) {
  const s = [...String(blk || '').matchAll(/^-\s*log:\s*(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)/gm)]
    .map((m) => Date.parse(m[1])).filter((n) => Number.isFinite(n));
  return s.length ? Math.max(...s) : 0;
}

export const ROLE_PREFIXES = [
  'planner', 'plan-?reviewer', 'planrev', 'architect', 'arch',
  'developer', 'dev', 'code-?reviewer', 'cr', 'reviewer',
  'designer', 'uiux(?:-designer)?',
];
const ROLE_ALT = ROLE_PREFIXES.join('|');

const ROLE_TOKEN = new RegExp(`(?:^|[^a-z])(${ROLE_ALT})(?![a-z_])`, 'i');
export function newestRoleLogOfBlock(blk) {
  const s = [...String(blk || '').matchAll(/^-\s*log:\s*(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)\s*·?\s*(.*)$/gm)]
    .filter((m) => ROLE_TOKEN.test(m[2] || ''))
    .map((m) => Date.parse(m[1])).filter((n) => Number.isFinite(n));
  return s.length ? Math.max(...s) : 0;
}


const H = 3600 * 1000;

const ACK_ANY_G = /(?:MERGED[\s*_`~]{0,4}#(\d+)|#(\d+)[\s*_`~]{0,4}MERGED)/gi;

function newestGateObservedAt(block) {
  const hits = [...String(block || '').matchAll(/gate-observed-at\s*=\s*(\d{4}-\d{2}-\d{2}T[\d:xX]{5,8}Z)/gi)]
    .map((m) => Date.parse(m[1].replace(/[xX]/g, '0')))
    .filter((t) => Number.isFinite(t));
  return hits.length ? Math.max(...hits) : null;
}
const LOG_DATE_RE = /-\s*(?:log:\s*)?(\d{4})-(\d{2})-(\d{2})(?:[\sT·]*(\d{1,2})[:.]?\dxZ?|[\sT·]*(\d{1,2}):(\d{2}))?/g;


const AGENT_NAME_RE = /\b((?:planner|planrev|plan-reviewer|architect|arch|dev|developer|cr|code-reviewer|uiux|designer)[a-z0-9-]*-r\d+[a-z]?)\b/i;
export function phantomDispatchLogs(blockText, roster, now = Date.now(), windowMs = 2 * 60 * 60_000) {
  if (!Array.isArray(roster)) return [];
  const rows = [...String(blockText || '')
    .matchAll(/^-\s*log:\s*(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)\s*(.*)$/gm)]
    .map((m) => ({ ts: Date.parse(m[1]), rest: m[2] || '' }))
    .filter((r) => Number.isFinite(r.ts));
  if (!rows.length) return [];
  const newest = rows.reduce((a, b) => (b.ts > a.ts ? b : a));
  if (now - newest.ts > windowMs) return [];
  const named = (newest.rest.match(AGENT_NAME_RE) || [])[1];
  if (!named) return [];
  return roster.some((n) => String(n).toLowerCase() === named.toLowerCase())
    ? [] : [{ ts: newest.ts, agent: named, row: newest.rest.trim() }];
}

function effectiveLastLog(blockText, now) {
  const phantom = phantomDispatchLogs(blockText, liveAgentNames(), now);
  if (!phantom.length) return newestLogTs(blockText);
  const ghostTs = phantom[0].ts;
  const older = [...String(blockText || '')
    .matchAll(/^-\s*log:\s*(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)/gm)]
    .map((m) => Date.parse(m[1]))
    .filter((n) => Number.isFinite(n) && n < ghostTs);
  return older.length ? Math.max(...older) : 0;
}

function newestLogTs(blockText) {
  const text = String(blockText || '');
  const exact = [...text.matchAll(/^-\s*log:\s*(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)/gm)]
    .map((m) => Date.parse(m[1]))
    .filter((n) => Number.isFinite(n));
  if (exact.length) return Math.max(...exact);

  let latest = 0;
  for (const m of text.matchAll(LOG_DATE_RE)) {
    const [, y, mo, d, hx, hf] = m;
    const hour = hx != null ? +hx : hf != null ? +hf : 12;
    const ts = Date.UTC(+y, +mo - 1, +d, Math.min(23, hour), hx != null || hf != null ? 30 : 0, 0);
    if (ts > latest) latest = ts;
  }
  return latest || null;
}

const nameOf = (h) => (String(h).match(/R-[a-z0-9-]+/i) || ['(card)'])[0];

export function actionableGhosts(v) {
  const owed = v.owed || [];
  const lockActive = Boolean(v.dodFailedPresent
    || owed.some((o) => o && String(o.kind || '').startsWith('DoD-FAILED')));
  const handedOff = new Set(owed
    .filter((o) => String(o.kind || '').startsWith('DoD-FAILED')
      && (o.tracks || []).length && !(o.idleTracks || []).length)
    .map((o) => o.card));
  const mergeOrderGated = (g) => Boolean(g.gated) && /^merge-order:/.test(String(g.blocker || ''));
  const owesABaton = (g) => Boolean(g.openVerdict);
  return (v.ghosts || []).filter(
    (g) => ((!g.blocker && !g.gated) || (mergeOrderGated(g) && owesABaton(g)))
      && !handedOff.has(g.card)
      && !(lockActive && !g.isDodFailed && !g.isDodRemedy)
      && !(v.highest != null && g.tier != null && g.tier > v.highest),
  );
}

export function pilotVerdict(boardText, now = Date.now(), opts = {}) {
  const { mergedPRs = null, allMerges = null, mergeUnavailableReason = '', openPRs = null, archiveText = '', approvedAtHead = null, planVerdicts = null, allVerdicts = null, rosterMembers = null } = opts;

  const gateFields = (block, header) => {
    const raw = liveBlocker(header);
    const live = (raw && /^merge-order:/.test(raw))
      ? (mergeOrderGateOnHeader(boardText, header) || null)
      : raw;
    return { gated: isGatedOrObserving(block, now) && !(raw && !live), blocker: live };
  };
  const cards = String(boardText || '').split(/\n(?=### \[)/)
    .filter((c) => /^### \[/.test(c))
    .map((block) => {
      const header = block.split('\n')[0];
      return {
        block, header, name: nameOf(header), status: statusOf(header),
        tier: priorityOf(header), ...gateFields(block, header),
        ttlH: ttlHoursFor(header), lastLog: effectiveLastLog(block, now),
        stage: stageOf(header), stageHolds: STAGE_HOLDS.has(stageOf(header)),
      };
    });

  const openSlugs = new Set(cards.map((c) => ownSlugOf(c.header)).filter(Boolean));

  const archCards = String(archiveText || '').split(/\n(?=### )/)
    .filter((c) => /^### /.test(c))
    .map((block) => {
      const header = block.split('\n')[0];
      return {
        block, header, name: nameOf(header), status: statusOf(header),
        tier: priorityOf(header), ...gateFields(block, header),
        ttlH: ttlHoursFor(header), lastLog: effectiveLastLog(block, now),
        stage: stageOf(header), stageHolds: STAGE_HOLDS.has(stageOf(header)),
        archived: true,
      };
    });

  const owed = [];
  for (const c of cards.concat(archCards)) {
    if (!c.archived && isDodFailed(c.block)) {
      const anchors = dodFailedAnchors(c.block);
      const last = anchors[anchors.length - 1];
      const archHeads = String(archiveText || '').split(/\n(?=### )/)
        .map((b) => b.split('\n')[0]).filter((h) => /^### /.test(h));
      const declaredTracks = dodRemedyTracks(c.header);
      const doneTracks = declaredTracks.filter((t) => !cards.some((x) => slugOf(x.header) === t)
        && archHeads.some((h) => new RegExp(`\\]\\s*(?:PR\\s*#\\d+\\s*·\\s*)?${t}(?:\\s|·)`).test(h)));
      const tracks = declaredTracks.filter((t) => cards.some((x) => slugOf(x.header) === t));
      const doneNote = doneTracks.length ? ` · **${doneTracks.length} complete and archived**: ${doneTracks.join(', ')}` : '';
      const trackNote = (tracks.length ? ` · remedy tracks (named on this card): ${tracks.join(', ')}` : '') + doneNote;
      const isRemedy = /\bdod-remedy-for=/.test(c.header);
      const stageFromVerdict = (t) => {
        if (!planVerdicts) return null;
        const v = planVerdicts[t];
        if (!v || !/^APPROVED/.test(String(v.verdict || ''))) return null;
        return 'plan-ok';
      };
      const STAGE_ORDER = ['new', 'planning', 'plan-ok', 'arch', 'arch-ok', 'dev', 'pr', 'review', 'merged'];
      const trackStage = (t) => {
        const x = cards.find((y) => slugOf(y.header) === t);
        if (!x) return null;
        const onCard = stageOf(x.header) || 'new';
        const fromV = stageFromVerdict(t);
        if (!fromV) return onCard;
        return STAGE_ORDER.indexOf(fromV) > STAGE_ORDER.indexOf(onCard) ? fromV : onCard;
      };
      const stageIsBehind = (t) => {
        const x = cards.find((y) => slugOf(y.header) === t);
        if (!x) return false;
        const onCard = stageOf(x.header) || 'new';
        const fromV = stageFromVerdict(t);
        return !!fromV && STAGE_ORDER.indexOf(fromV) > STAGE_ORDER.indexOf(onCard);
      };
      const trackIsIdle = (t) => trackStage(t) === 'new';
      const trackNeedsReview = (t) => {
        if (!openPRs || !approvedAtHead) return false;
        const x = cards.find((y) => slugOf(y.header) === t);
        if (!x || trackStage(t) === 'new') return false;
        if (trackStage(t) === 'review') return false;
        const nums = [...String(x.header || '').matchAll(/PR\s*#(\d+)/g)].map((m) => Number(m[1]));
        const st = trackStage(t);
        if (STAGE_HOLDS.has(st) && Array.isArray(rosterMembers)
          && nums.some((n) => rosterHoldsCard({ members: rosterMembers, stage: st, prNumber: n }))) return false;
        return nums.some((n) => {
          const meta = Object.prototype.hasOwnProperty.call(openPRs, n) ? openPRs[n] : null;
          if (!meta) return false;
          if ((meta.red || []).length) return false;
          return approvedAtHead[n] !== true;
        });
      };
      const trackIsStuck = (t) => {
        if (!openPRs || !approvedAtHead) return false;
        const x = cards.find((y) => slugOf(y.header) === t);
        if (!x || trackStage(t) === 'new') return false;
        const nums = [...String(x.header || '').matchAll(/PR\s*#(\d+)/g)].map((m) => Number(m[1]));
        return nums.some((n) => {
          const meta = Object.prototype.hasOwnProperty.call(openPRs, n) ? openPRs[n] : null;
          if (!meta) return false;
          if (approvedAtHead[n] !== true) return false;
          const ms = String(meta.mergeState || '').toUpperCase();
          return (ms === 'BEHIND' || ms === 'DIRTY' || ms === 'CLEAN') && !(meta.red || []).length;
        });
      };
      const idleTracks = tracks.filter(trackIsIdle);
      const stuckTracks = tracks.filter(trackIsStuck);
      const reviewTracks = tracks.filter(trackNeedsReview);
      const nextRoleTracks = tracks.filter((t) => {
        if (idleTracks.includes(t) || stuckTracks.includes(t) || reviewTracks.includes(t)) return false;
        const st = trackStage(t);
        const role = NEXT_BY_STAGE[st];
        if (STAGE_HOLDS.has(st) && HOLDER_ROLE[st] === role) return false;
        return !!role && st !== 'pr' && st !== 'review';
      }).map((t) => ({ track: t, stage: trackStage(t), role: NEXT_BY_STAGE[trackStage(t)], behind: stageIsBehind(t) }));
      owed.push({ kind: 'DoD-FAILED', card: c.name, status: c.status, tracks, isRemedy, idleTracks, stuckTracks, reviewTracks, nextRoleTracks, doneTracks, detail: `dod-failed-at=${last}, ${((now - Date.parse(last)) / H).toFixed(1)}h ago — a failed DoD outranks every new wave${trackNote}` });
      continue;
    }
    if (!c.archived && isDodFailedDialectDrift(c.block)) {
      owed.push({ kind: 'DoD-FAILED (unanchored)', card: c.name, status: c.status, detail: 'the card asserts a LIVE DoD failure with no `dod-failed-at=` field — the enforcing gate cannot see it' });
      continue;
    }
    const nl = c.block.indexOf('\n');
    const hdrLine = nl < 0 ? c.block : c.block.slice(0, nl);
    const bodyText = nl < 0 ? '' : c.block.slice(nl + 1);
    const ACK_BODY_G = /✅[\s*_`~]{0,4}(?:MERGED[\s*_`~]{0,4}#(\d+)|#(\d+)[\s*_`~]{0,4}MERGED)/gi;
    const ackPRs = [...new Set([
      ...[...hdrLine.matchAll(ACK_ANY_G)].map((m) => Number(m[1] || m[2])),
      ...(c.archived ? [...bodyText.matchAll(ACK_BODY_G)].map((m) => Number(m[1] || m[2])) : []),
    ].filter((n) => Number.isFinite(n) && n > 0))];
    const known = allMerges === null ? null : new Set(allMerges.map((p) => p.n));
    const ownedPRs = ownedPRsIn(hdrLine);
    const ghMerged = known ? ownedPRs.filter((n) => known.has(n)) : [];
    const ackedMerges = known
      ? [...new Set([...ackPRs.filter((n) => known.has(n)), ...ghMerged])]
      : ackPRs.slice(0, 1);
    const ARCHIVE_BLINDSPOT_SINCE = Date.parse('2026-08-03T00:00:00Z');
    const archivedAndUnclaimed = c.archived
      && !NO_DOD_NEEDED_RE.test(c.header)
      && lastDodWord(c.header) === null;
    if (ackedMerges.length && (OPEN_STATUSES.includes(c.status) || archivedAndUnclaimed)) {
      const ageH = c.lastLog ? (now - c.lastLog) / H : null;
      const v = classifyDodLadder(c.block, ageH);
      const gateWaveDead = v.tag === 'GATED' && v.wave
        && !waveGateIsLive(v.wave, openSlugs);
      const scopeNarrowed = SCOPE_NARROWED_DOD_RE.test(c.header);
      const settled = ['VERIFIED', 'GATED'].includes(v.tag) && !gateWaveDead && !scopeNarrowed;
      const settledAt = newestGateObservedAt(c.block);
      for (const n of ackedMerges) {
        const pr = allMerges ? allMerges.find((p) => p.n === n) : null;
        const prTs = pr ? Date.parse(pr.ts) : NaN;
        const postDatesSettlement = settled && settledAt != null && Number.isFinite(prTs) && prTs > settledAt;
        if (c.archived && pr && Date.parse(pr.ts) < ARCHIVE_BLINDSPOT_SINCE) continue;
        const verifiedButStillActive = v.tag === 'VERIFIED' && !c.archived;
        if (settled && !postDatesSettlement && !verifiedButStillActive) continue;
        owed.push({
          kind: gateWaveDead
            ? 'DoD owed (its merge-order:wave gate names a wave that is NO LONGER an open card — the gate expired by its own terms)'
            : postDatesSettlement
              ? 'DoD owed (merged AFTER the card\'s settlement — that gate cannot cover it)'
              : verifiedButStillActive
                ? 'DoD owed (ladder says VERIFIED but the card is STILL ON THE ACTIVE BOARD — archive it, or that VERIFIED is scoped to a layer and must not sit in a card-level position)'
                : 'DoD owed (merged, unverified)',
          card: c.name, status: c.status, ladder: v.tag, pr: n, mergedAt: pr ? Date.parse(pr.ts) : null,
          detail: `PR #${n} merged${pr ? ` @${pr.sha} (${String(pr.ts).slice(0, 10)})` : ''}; ladder=${v.tag}${v.gateReason ? ` (${v.gateReason})` : ''}${gateWaveDead ? `, but its gate waits on wave \`${v.wave}\` which is NOT on the active board (archived/renamed/never existed) — do the DoD, or re-point the gate at something that can still expire` : ''}${postDatesSettlement ? `, but the card's newest \`gate-observed-at=\` is ${new Date(settledAt).toISOString().slice(0, 19)}Z — EARLIER than this merge, so that settlement was recorded before this PR existed and provably does not cover it` : ''}${ageH != null ? `, ${ageH.toFixed(0)}h since last log (P-timer ${c.ttlH}h)` : ''} — clears by landing DoD evidence + archiving, or by a DATED \`observe-until YYYY-MM-DD\` + a FRESH \`gate-observed-at=<ISO Z>\``,
        });
      }
    }
  }

  let mergeSource = 'main';
  if (mergedPRs === null) {
    mergeSource = 'UNAVAILABLE';
  } else {
    for (const pr of mergedPRs) {
      if (owed.some((o) => o.pr === pr.n)) continue;
      owed.push({
        kind: 'DoD owed (merged on main, NO CARD CLAIMS IT)', card: `PR #${pr.n}`, status: '(none)', pr: pr.n,
        detail: `#${pr.n} \`${pr.branch || '?'}\` landed on main @${pr.sha} (${String(pr.ts).slice(0, 10)}) and NO card in the active board or any archive file claims it — ack, branch slug and title slug all miss => merged, but on nobody's DoD ledger. Note that reconcile is structurally blind to this class: it only matches merges to cards it already knows. Title: ${pr.subject || ''}`,
      });
    }
  }

  const openCards = cards.filter((c) => OPEN_STATUSES.includes(c.status));

  const effTier = effectivePriorityMap(cards.map((c) => ({ name: c.name, header: c.header })));
  for (const c of cards) {
    const e = effTier.get(c.name);
    if (e != null && (c.tier == null || e < c.tier)) { c.ownTier = c.tier; c.tier = e; }
  }

  for (const c of cards) {
    if (c.ownTier == null) continue;
    const mine = { pr: (c.header.match(/\bPR\s*#(\d{2,5})\b/) || [])[1] || null,
      slug: (c.header.match(/\b(R-[a-z0-9][a-z0-9-]{4,})/) || [])[1] || null };
    const waiters = cards.filter((w) => {
      if (w === c) return false;
      const wp = (w.header.match(/blocked-by=merge-order:pr#(\d{2,5})/i) || [])[1];
      const ww = (w.header.match(/blocked-by=merge-order:wave:(R-[a-z0-9][a-z0-9-]*)/i) || [])[1];
      return (wp && mine.pr && wp === mine.pr)
        || (ww && mine.slug && ww.toLowerCase() === mine.slug.toLowerCase());
    });
    if (waiters.length) c.liftedBy = waiters.map((w) => ({ name: w.name, tier: w.tier }));
  }

  const holders = openCards.filter((c) => !c.gated && c.tier !== null);
  const highest = holders.length ? Math.min(...holders.map((c) => c.tier)) : null;

  const claimedBusy = (c) => c.status !== 'QUEUED' || c.stageHolds;
  const candidates = highest === null ? []
    : openCards.filter((c) => !claimedBusy(c) && !c.gated && c.tier === highest).map((c) => c.name);
  const inFlight = highest === null ? []
    : holders.filter((c) => c.tier === highest && claimedBusy(c)).map((c) => `${c.name} [${c.status}${c.stageHolds && c.status === 'QUEUED' ? ` · stage=${c.stage}` : ''}]`);

  const tiers = [];
  for (const t of [0, 1, 2, 3]) {
    const atTier = openCards.filter((c) => c.tier === t);
    if (!atTier.length) { tiers.push({ tier: t, verdict: 'empty', detail: 'no open cards at this tier' }); continue; }
    if (highest !== null && t > highest) {
      tiers.push({ tier: t, verdict: 'blocked-by-wave-order', detail: `blocked-by=wave-order:P${highest}-tier-not-landed — ${holders.filter((c) => c.tier === highest).length} P${highest} card(s) still open. This clears itself; do NOT hand-write it onto a card.` });
      continue;
    }
    const gatedHere = atTier.filter((c) => c.gated);
    const openHere = atTier.filter((c) => !c.gated);
    if (!openHere.length) {
      tiers.push({ tier: t, verdict: 'all-gated', detail: gatedHere.map((c) => `${c.name} → blocked-by=${c.blocker}`).join(' · ') || 'every card here is gated' });
      continue;
    }
    tiers.push({ tier: t, verdict: t === highest ? 'OPENABLE' : 'open', detail: openHere.map((c) => `${c.name} [${c.status}]`).join(' · ') });
  }

  const corrections = [];
  const suggestions = [];
  const ghosts = [];
  const GHOST_MIN_H = 1;
  for (const c of openCards) {
    if (!claimedBusy(c) || c.lastLog === null) continue;
    const staleH = (now - c.lastLog) / H;
    const claimed = openPRs ? [...String(c.header || '').matchAll(/PR\s*#(\d+)/g)].map((m) => Number(m[1])) : [];
    const openClaim = openPRs === null
      ? /PR\s*#\d+\s*(?:OPEN|open|opened)/.test(c.block)
      : claimed.some((n) => Object.prototype.hasOwnProperty.call(openPRs, n));
    const wtRaw = (opts.liveCards && opts.liveCards[c.name]) || null;
    const wtLive = (wtRaw && Number.isFinite(wtRaw.ageMs) && wtRaw.ageMs < WT_FRESH_MS) ? wtRaw : null;
    const revAges = opts.reviewAges || null;
    const revLive = !!(revAges && Object.keys(revAges).some(
      (stem) => (c.name.startsWith(stem) || stem.startsWith(c.name)) && revAges[stem] < WT_FRESH_MS,
    ));
    const hasLiveWork = openClaim || /\bIteration Contract\b/i.test(c.block) || !!wtLive || revLive;
    const cardVerdict = (allVerdicts && allVerdicts[c.name]) || null;
    const heldByWave = rosterHoldsCardByWave({ members: rosterMembers, cardBlock: c.block });
    const openVerdict = cardVerdict && !heldByWave ? cardVerdict : null;
    if (openVerdict || (!hasLiveWork && staleH > GHOST_MIN_H)) {
      const gateTarget = headlineTargetFor(
        { card: c.name, blocker: c.blocker, gated: c.gated }, cards.map((x) => x.header),
      );
      ghosts.push({ card: c.name, status: c.status, staleH: staleH.toFixed(1), ttlH: c.ttlH, stage: c.stage, blocker: c.blocker, gated: c.gated, tier: c.tier, ownTier: c.ownTier ?? null, liftedBy: c.liftedBy || null, openVerdict, gateTarget, wtChecked: !!wtRaw, wt: wtRaw ? wtRaw.wt : null, branch: wtRaw ? (wtRaw.branch || null) : null, delivered: !!(wtRaw && wtRaw.delivered), unpushed: wtRaw ? (wtRaw.unpushed ?? null) : null, tip: wtRaw ? (wtRaw.tip || null) : null, deliveredAgoMin: wtRaw ? (wtRaw.deliveredAgoMin ?? null) : null, pr: (c.header.match(/\bPR\s*#(\d{2,5})\b/) || [])[1] || null, isDodFailed: isDodFailed(c.block), isDodRemedy: Boolean(dodRemedyFor(c.block)) });
    }
    const PR_IDLE_H = GHOST_MIN_H;
    if (hasLiveWork && staleH > PR_IDLE_H) {
      void PR_IDLE_H;
    }
    if (staleH > c.ttlH && !hasLiveWork && !c.gated) {
      corrections.push({ card: c.name, from: c.status, to: 'QUEUED', why: `no open PR, ${wtRaw ? `no file touched in its worktree for ${(WT_FRESH_MS / 60000) | 0}min` : 'no worktree found for it (artifact freshness UNMEASURED)'}, and the card's newest log is ${staleH.toFixed(0)}h old (P-timer ${c.ttlH}h) — while it sits in [${c.status}] it is invisible to the openable list, which is the silent-stall mode` });
    }
  }
  for (const c of openCards) {
    if (c.status !== 'QUEUED' || c.gated) continue;
    const claimedOpen = [...String(c.header || '').matchAll(/PR\s*#(\d+)\s*(?:OPEN|open|opened)/g)].map((m) => Number(m[1]));
    if (!claimedOpen.length) continue;
    if (openPRs === null) {
      suggestions.push({ card: c.name, from: 'QUEUED', to: 'IN-DEV', why: `The card header says PR #${claimedOpen.join('/#')} OPEN, but **the list of open PRs is unavailable right now** (gh not reachable), so it cannot be checked. Run \`gh pr view <N>\` yourself before deciding — do not advance a status badge on the strength of what the board says.` });
      continue;
    }
    const stillOpen = claimedOpen.filter((n) => Object.prototype.hasOwnProperty.call(openPRs, n));
    if (stillOpen.length) {
      suggestions.push({ card: c.name, from: 'QUEUED', to: 'IN-DEV', why: `GitHub says PR #${stillOpen.join('/#')} really is open => work is in flight and the status badge is behind. Confirm that PR belongs to THIS card before advancing it — advancing the wrong one stalls it silently.` });
    } else {
      corrections.push({ card: c.name, from: 'QUEUED', to: 'QUEUED', why: `THE CARD HEADER IS LYING: it says PR #${claimedOpen.join('/#')} OPEN, and GitHub says those PRs are no longer open — merged or closed. FIX: change \`OPEN\` in the card header to the real state (\`MERGED #N\`), or archive the card. The drift hook cannot see this: the card carries a MERGED ack elsewhere, so every check passes and only that one word in the header is stale.` });
    }
  }

  const ghostSource = openPRs === null ? 'PROSE-FALLBACK' : 'github';
  return { owed, highest, candidates, inFlight, tiers, ghosts, corrections, suggestions, ghostSource, mergeSource, mergeUnavailableReason, rosterMembers: opts.rosterMembers ?? null, counts: { cards: cards.length, open: openCards.length, holders: holders.length, mergedPRs: mergedPRs ? mergedPRs.length : null } };
}


const REWORK_OWNER = { CHANGES_REQUIRED: 'developer', NEEDS_REVISION: 'planner' };
export function headlineTargetFor(g, cardHeaders) {
  const self = String((g && g.card) || '');
  if (!self) return '';
  const blk = String((g && g.blocker) || '');
  if (!g.gated || !/^merge-order:/.test(blk)) return self;
  const headers = Array.isArray(cardHeaders) ? cardHeaders : [];
  const mPr = /^merge-order:pr#(\d+)$/.exec(blk);
  if (mPr) {
    for (const h of headers) {
      if (!new RegExp(`(?:PR|MERGED)\\s*#${mPr[1]}\\b`).test(h)) continue;
      const owner = nameOf(h);
      if (owner && owner !== self) return owner;
    }
    return self;
  }
  const mWave = /^merge-order:wave:(.+)$/.exec(blk);
  if (mWave) {
    const want = mWave[1].trim().toLowerCase();
    for (const h of headers) {
      if (String(slugOf(h) || '').toLowerCase() !== want) continue;
      const owner = nameOf(h);
      if (owner && owner !== self) return owner;
    }
  }
  return self;
}


export function nextRoleForGhost(g) {
  if (g && g.delivered) {
    const st = String(g.stage || '');
    const verdict = String((g.openVerdict && g.openVerdict.verdict) || '');
    if (verdict && verdict !== 'APPROVED') return REWORK_OWNER[verdict] || NEXT_AFTER_DELIVERY[st] || '';
    return NEXT_AFTER_DELIVERY[st] || '';
  }
  return nextRoleForIdleGhost(g);
}

function nextRoleForIdleGhost(g) {
  const stage = String((g && g.stage) || '');
  const verdict = String((g && g.openVerdict && g.openVerdict.verdict) || '');
  if (verdict === 'APPROVED') {
    return /^plan/.test(stage) ? 'architect' : (NEXT_BY_STAGE[stage] || '');
  }
  if (REWORK_OWNER[verdict]) return REWORK_OWNER[verdict];
  return NEXT_BY_STAGE[stage] || '';
}


function liftedNote(g) {
  if (!g || !g.liftedBy || !g.liftedBy.length) return '';
  const who = g.liftedBy
    .map((w) => `${w.name}${w.tier != null ? `(P${w.tier})` : ''}`)
    .join(' · ');
  const from = g.ownTier != null ? `originally P${g.ownTier}, ` : '';
  return `\n   **${from}raised to P${g.tier}: ${who}'s \`merge-order\` is waiting on it.**`
    + ` Finish and merge THIS one and that one unblocks — doing it the other way round is a deadlock.`;
}

function nextAction(v) {
  if (v.owed && v.owed.length) {
    const failed = v.owed.filter((o) => /DoD-FAILED/.test(o.kind));
    const failedWithIdle = failed.filter((f) => (f.idleTracks || []).length || (f.stuckTracks || []).length || (f.reviewTracks || []).length);
    const leadWalkable = v.owed
      .filter((x) => /\bmerged\b/i.test(x.kind || ''))
      .sort((a, b) => (a.mergedAt ?? Infinity) - (b.mergedAt ?? Infinity));
    const o = leadWalkable.length ? leadWalkable[0]
      : failedWithIdle.length ? failedWithIdle[0]
        : failed.length ? failed[0] : v.owed[0];
    const others = v.owed.filter((x) => x.card !== o.card).length;
    if (/DoD-FAILED/.test(o.kind)) {
      const list = o.tracks || [];
      const idle = o.idleTracks || [];
      const stuck = o.stuckTracks || [];
      const needRev = o.reviewTracks || [];
      const done = o.doneTracks || [];
      const nextRole = o.nextRoleTracks || [];
      const doneTail = done.length ? ` (${done.length} more **complete and archived**)` : '';
      const tracks = !list.length && !done.length
        ? `**there is no remedy track yet** => open a remedy card first (header \`dod-remedy-for=${o.card}\`) and add \`dod-remedy-tracks=\` back on this card, or that card cannot be dispatched.`
        : (stuck.length || idle.length || needRev.length || nextRole.length)
          ? [
            stuck.length ? `**merge these ${stuck.length}** (verdict APPROVED, pinned to the current head, zero red): ${stuck.join(' · ')}` : '',
            needRev.length ? `**dispatch a fresh code-reviewer for these ${needRev.length}** (PR open, zero red, but the verdict is not APPROVED pinned to the current head => they owe a review round, not a merge): ${needRev.join(' · ')}` : '',
            nextRole.length ? nextRole.map((x) => `**dispatch \`${x.role}\`** for ${x.track} (its own \`stage=${x.stage}\`${x.behind ? ' — the card header\'s `stage=` is BEHIND the verdict; fix it while you are there' : ''})`).join(' ;; ') : '',
            idle.length ? `**open these ${idle.length}** (stage=new): ${idle.join(' · ')}` : '',
          ].filter(Boolean).join(' ;; ') + doneTail
          : list.length
            ? ''
            : `the remedy tracks are **all complete and archived** (${done.length}) => come back and walk this card's own DoD. Do not open another remedy card.`;
      if (tracks === '') return '';
      const trackSet = new Set(list);
      const otherCards = v.owed.filter((x) => x.card !== o.card);
      const nowDoable = otherCards.filter((x) => trackSet.has(x.card) || /\bmerged\b/i.test(x.kind || ''));
      const trulyBlocked = otherCards.length - nowDoable.length;
      const otherLine = [
        nowDoable.length
          ? `\n   ${nowDoable.length} more are **doable right now** (remedy tracks, or merged and owing only acceptance => the DoD is yours to walk, not through the dispatch gate):`
            + `\n      ${nowDoable.map((x) => x.card).join(' · ')}`
          : '',
        trulyBlocked ? `\n   ${trulyBlocked} more also owe a DoD and **cannot be touched now** (the dispatch gate admits only FAILED cards and their remedy tracks).` : '',
      ].join('');
      const head = (stuck.length || idle.length || needRev.length || nextRole.length)
        ? `DO THIS: ${tracks}\n   (source: ${o.card}'s DoD did not pass => the dispatch gate currently admits only that card and its remedy tracks)`
        : `DO THIS: ${o.card}'s DoD ran and did not pass — it is a hard lock and it holds down everything else on the board.\n   ${tracks}`;
      return head + otherLine;
    }
    const more = others ? ` (${others} more still owed)` : '';
    const prTag = o.pr ? `#${o.pr}` : '';
    const when = o.mergedAt ? new Date(o.mergedAt).toISOString().slice(11, 16) + 'Z' : '';
    return `WALK ${o.card}'s DoD — ${prTag} is merged${when ? ` (${when}, the oldest unsettled entry on the board)` : ''}, `
      + `and the DoD is yours to walk by hand, not through the dispatch gate.${more}\n`
      + `   Start with its \`- ship:\` line, which says what is still owed after the merge; verify each item against the **production artifact**, `
      + `then write \`DoD-VERIFIED\` and archive it.`;
  }
  const actionable = actionableGhosts(v);
  if (actionable.length) {
    const openable = actionable.find((x) => !(x.gated && /^merge-order:/.test(String(x.blocker || ''))));
    if (!openable) {
      const blocked = actionable[0];
      if (blocked.gateTarget && blocked.gateTarget !== blocked.card) {
        return `PUSH ${blocked.gateTarget} FIRST — ${blocked.card} is gated on `
          + `\`${String(blocked.blocker || '').slice(0, 40)}\` waiting for it; once that merges, this card's gate clears itself.`;
      }
    }
    const g = openable || actionable[0];
    if (g.delivered) {
      const role = nextRoleForGhost(g);
      const push = g.unpushed > 0
        ? `push first, from the main checkout, as its own command: \`git -C ${projectPaths()?.repo || '<main-checkout>'} push origin ${g.branch || '<branch>'}\`, then `
        : 'already pushed => ';
      return `${g.card}: THAT BATON DELIVERED AND YOU DID NOT HAND OFF${g.deliveredAgoMin != null ? ` (its artifact has been still for ${g.deliveredAgoMin}min)` : ''}. ` +
        `${push}${role ? `dispatch \`${role}\`` : 'dispatch the next baton'}${g.tip ? `, pinning \`${g.tip}\` in the brief` : ''}.\n` +
        `   Record \`- log: <ISO Z> · <who was dispatched>\` on the card in the SAME turn — once that log stamp passes the artifact time, this layer clears itself.\n` +
        `   It is holding the slot and nobody is working it.${liftedNote(g)}`;
    }
    if (g.openVerdict) {
      const ov = g.openVerdict;
      const role = nextRoleForGhost(g);
      const idx = `${projectPaths()?.repo || '<repo>'}/.claude/reviews/index.jsonl`;
      return `${g.card} — verdict \`${ov.verdict}\` @${ov.ts}, and nobody took the baton.\n` +
        `   1. \`grep '"card":"${g.card}"' ${idx} | tail -1\` => read the \`.md\` it names.\n` +
        `   2. accept it or send it back, then dispatch \`${role || '<the next baton>'}\`.${liftedNote(g)}`;
    }
    return `${g.card}: IDLE, AND NO NEW ARTIFACT — zero file changes in the worktree for ${(WT_FRESH_MS / 60000) | 0}min, ` +
      `and the newest commit is no newer than the dispatch stamp on the card.\n` +
      `   1. idle >30min => ping it, and record \`- log:\` on the card.\n` +
      `   2. still idle 30min later => re-dispatch the SAME role. Do not touch \`stage=\`, do not revert to [QUEUED]; the brief names the dead predecessor and where its artifact is.\n` +
      `   It is holding the slot.${liftedNote(g)}`;
  }
  if (v.candidates && v.candidates.length) {
    const capped = capOf(v);
    if (capped) return `OK: no openable card (worktree ${wtCount()}/${WT_CAP}).`;
    return `DO THIS: open ${v.candidates[0]} (P${v.highest}, the highest openable tier). ` +
      `Live-verify its premise first-hand, then dispatch the planner.${v.candidates.length > 1 ? ` ${v.candidates.length - 1} more card(s) sit at the same tier.` : ''}`;
  }
  if (v.inFlight && v.inFlight.length) {
    return `OK: no card should be opened — P${v.highest} has ${v.inFlight.length} in flight holding the slot, and we do not descend a tier before they land.`;
  }
  return `OK: nothing on the board needs your hands right now.`;
}

function capOf(v) {
  if (typeof v?.atCap === 'boolean') return v.atCap;
  return wtAtCapFor({
    openable: (v?.candidates || []).length,
    inFlightSameTier: (v?.inFlight || []).length,
  });
}

export function renderVerdict(v) {
  const L = [];

  if (v.owed.length) {
    const seen = new Set();
    const rows = [];
    const parked = [];
    for (const o of v.owed) {
      if (seen.has(o.card)) continue;
      seen.add(o.card);
      const isFailed = /DoD-FAILED/.test(o.kind);
      const idleT = o.idleTracks || [];
      const stuckT = o.stuckTracks || [];
      const revT = o.reviewTracks || [];
      const doneT = o.doneTracks || [];
      const nextRoleT = o.nextRoleTracks || [];
      const tracks = (o.tracks || []).length;
      if (isFailed && tracks && !idleT.length && !stuckT.length && !revT.length && !nextRoleT.length) { parked.push(o.card); continue; }
      const doneNote = doneT.length ? ` · ${doneT.length} complete` : '';
      const why = isFailed
        ? (tracks
          ? [
            stuckT.length ? `**merge these ${stuckT.length}** (wave finished, verdict APPROVED, zero red, only the merge is left): ${stuckT.join(' · ')}` : '',
            revT.length ? `**dispatch a fresh code-reviewer for these ${revT.length}** (PR open, zero red, but the verdict is not pinned to the current head => a review round is owed): ${revT.join(' · ')}` : '',
            nextRoleT.length ? nextRoleT.map((x) => `**dispatch \`${x.role}\`** for ${x.track} (its own \`stage=${x.stage}\`${x.behind ? ' — the card header\'s `stage=` is BEHIND the verdict; fix it while you are there' : ''})`).join(' ;; ') : '',
            idleT.length ? `**open these ${idleT.length}** (stage=new, never dispatched): ${idleT.join(' · ')}` : '',
          ].filter(Boolean).join(' ;; ') + doneNote
          : doneT.length
            ? `the remedy tracks are **all complete and archived** (${doneT.length}) => **walk this card's own DoD** (by hand, not through the dispatch gate). Do not open another remedy card`
            : 'the DoD ran and did not pass => **there is no remedy track yet; open one**')
        : /VERIFIED but/.test(o.kind) ? 'the card header says complete while it is still on the active board => **archive it**'
          : 'merged, not accepted => **walk its DoD** (by hand, not through the dispatch gate)';
      rows.push(`   • ${o.card} — ${why}`);
    }
    if (rows.length) {
      L.push(``, `1. DoD items you can do now: ${rows.length} (while anything is owed, DoD is the only work):`, ...rows);
    }
    if (parked.length) {
      L.push(`   ${parked.length} more DoD-FAILED card(s) whose **remedy tracks are all running, with nothing to do right now** (the hard lock stands; no need to look):`
        + `${parked.map((c) => c.slice(0, 34)).join(' · ')}`);
    }
  }
  if (v.mergeSource === 'UNAVAILABLE') {
    L.push(`   The merge scan is UNAVAILABLE — reason: ${v.mergeUnavailableReason || '(not recorded)'} => section 1 reflects only the card fields and is NOT evidence that nothing is owed.`);
  } else if (v.counts.mergedPRs) {
    L.push(`   ${v.counts.mergedPRs} merged PR(s) claimed by no card (ack / bare \`#N\` / branch slug / title slug all miss; bot bumps excluded).`);
  }

  if (!v.owed.length && v.highest != null && v.candidates.length && !capOf(v)) {
    L.push(``, `2. Openable **P${v.highest}** => ${v.candidates.join(' · ')}`);
    if (v.inFlight.length) L.push(`   ${v.inFlight.length} in flight at the same tier; do not descend before they land.`);
  }

  if (v.highest == null) {
    L.push(``, `3. Why each tier was skipped:`);
    for (const t of v.tiers) L.push(`   P${t.tier}: ${t.verdict} — ${t.detail}`);
  }

  const ghostsActionable = actionableGhosts(v);
  if (ghostsActionable.length) {
    L.push('');
    L.push(`${ghostsActionable.length} card(s) nobody is working (the entry reading is in brackets on each row):`);
    const actionFor = (g) => {
      if (g.blocker) {
        const target = g.gateTarget || '';
        if (target && target !== g.card) return `**push ${target} first**; once it merges, this card's gate clears itself`;
        return `**do nothing** — gated on \`${String(g.blocker).slice(0, 56)}\``;
      }
      if (v.highest != null && g.tier != null && g.tier > v.highest) {
        return `**do nothing** — P${g.tier} is below the currently openable P${v.highest}; it comes up once that tier clears. Do not raise a P level just to silence this`;
      }
      const role = nextRoleForGhost(g);
      if (!role) return `**\`stage=${g.stage || '(missing)'}\` has no next baton** — downstream gates dispatch from it. `
        + `If this is a merged source card, what it owes is a DoD or a gate, not a stage`;
      const holderRole = HOLDER_ROLE[String(g.stage || '')];
      if (holderRole && holderRole === role) {
        const held = Array.isArray(v.rosterMembers)
          ? rosterHoldsCard({ members: v.rosterMembers, stage: g.stage, prNumber: g.pr })
          : true;
        if (held && Array.isArray(v.rosterMembers) && g.wtChecked && !g.openVerdict) {
          return `**it DELIVERED, it is not working** — the roster still lists \`${role}\`, and its worktree `
            + `has had zero file changes for ${(WT_FRESH_MS / 60000) | 0}min => collect the handoff (ask of each item: is it DONE, or is it waiting on my ruling?), `
            + `rule on everything that waits, then \`shutdown_request\` and confirm it left the roster, then push, then open the PR, `
            + `then dispatch a brand-new \`code-reviewer\``;
        }
        if (held) {
          return `**do nothing** — the holder of \`stage=${g.stage}\` IS \`${role}\`, and it is working this card`;
        }
      }
      if (g.kind === 'pr-open-nobody-home') {
        const ms = String(g.mergeState || '');
        const redN = (g.red || []).length;
        const n = g.pr || '<N>';
        const wt = `${worktreeParent(projectPaths()?.repo) || '<worktree-parent>'}/<wave>`;
        if (redN) {
          return `\`gh pr checks ${n}\` — ${redN} red:`
            + `${(g.red || []).slice(0, 2).join(' · ')}; locate them by \`.steps[]\`, not by job conclusion`;
        }
        if (ms === 'BEHIND') {
          return `\`git -C ${wt} fetch origin && git -C ${wt} merge origin/main\`, then the lead pushes`
            + ` (**never rebase**) — zero red, this is the only step left`;
        }
        if (ms === 'DIRTY') {
          return `\`git -C ${wt} merge origin/main\`, resolve the conflicts, then the lead pushes (**never rebase**) — zero red, a real conflict`;
        }
        if (ms === 'CLEAN') {
          return `\`gh pr merge ${n} --squash --delete-branch\` — CLEAN and zero red`;
        }
        if (!ms) {
          return `\`gh pr view ${n} --json mergeStateStatus,statusCheckRollup\``
            + ` — this layer did not get a state; measure before judging`;
        }
        return `\`gh pr view ${n} --json mergeStateStatus,statusCheckRollup\``
          + ` — \`${ms}\`, zero red; let the reading pick the action`;
      }
      if (g.openVerdict) {
        return `**read the verdict -> accept it or send it back -> dispatch \`${role}\`** (\`${g.openVerdict.verdict}\` @${g.openVerdict.ts})`;
      }
      return `**dispatch \`${role}\`** (card header stage=${g.stage}, already matched)`;
    };
    for (const g of ghostsActionable) {
      L.push(`   • ${g.card}`);
      L.push(`     ⇒ ${actionFor(g)}`);
      L.push(g.kind === 'pr-open-nobody-home'
        ? `     (PR open, nobody working it · silent ${g.staleH}h, past the ${g.idleH}h idle line)`
        : g.openVerdict
          ? `     (entry condition = an unclosed verdict; idleness does not enter this judgement)`
          : `     (no open PR · ${g.wtChecked
            ? `zero file changes in ${g.wt || 'the worktree'} for ${(WT_FRESH_MS / 60000) | 0}min`
            : 'no worktree found for this card, so the artifact axis was NOT MEASURED'} · newest log on the card is ${g.staleH}h old, P-timer ${g.ttlH}h)`);
      const lifted = liftedNote(g);
      if (lifted) L.push(lifted.replace(/^\n {3}/, '     '));
    }
    L.push('   Record `- log: <ISO Z> · <who was dispatched>` on the card in the SAME turn');
    if (v.ghostSource === 'PROSE-FALLBACK') {
      L.push(`   This layer ran off the board text, not off GitHub facts (the open-PR list was unavailable), so it OVER-reports. Run \`gh pr list --state open\` before acting on it.`);
    }
  }
  if (v.corrections.length) {
    L.push(``, `4. Status needs reverting (direction: restore visibility):`);
    for (const c of v.corrections) L.push(`   • ${c.card} [${c.from}] → [${c.to}] — ${c.why}`);
  }
  if (v.suggestions.length) {
    L.push(``, `5. Advance suggestions (advisory only, never applied automatically — advancing the wrong card makes it vanish from the openable list):`);
    for (const s of v.suggestions) L.push(`   • ${s.card} [${s.from}] → [${s.to}]? — ${s.why}`);
  }

  while (L.length && L[0] === '') L.shift();
  const out = [nextAction(v)].filter((s) => s !== '');
  if (L.length) out.push(...(out.length ? [''] : []), `PILOT · ${v.counts.cards} card(s) / ${v.counts.open} open`, ...L);
  return out.join('\n');
}

if (process.argv[2] === '--name-prefix') {
  const nm = String(process.argv[3] || '').trim();
  if (!nm) process.stdout.write('SKIP');
  else {
    const re = new RegExp(`^(?:${ROLE_ALT})(?![a-z_])`, 'i');
    process.stdout.write(re.test(nm) ? 'OK' : 'BAD');
  }
}

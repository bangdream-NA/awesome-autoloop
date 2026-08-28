import { isDodFailed, isDodFailedDialectDrift, dodFailedAnchors, ttlHoursFor, isGated } from './backlog-gate.mjs';
import { readFileSync, readdirSync } from 'node:fs';
import * as nodePath from 'node:path';

export function archivePathsFor(backlogPath) {
  const dir = nodePath.dirname(backlogPath);
  const base = nodePath.basename(backlogPath).replace(/\.md$/i, '');
  const re = new RegExp(`^${base.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}-archive.*\\.md$`, 'i');
  try {
    return readdirSync(dir).filter((f) => re.test(f) && !/\.bak/i.test(f)).sort()
      .map((f) => nodePath.join(dir, f));
  } catch { return []; }
}
export function archiveTextFor(backlogPath) {
  return archivePathsFor(backlogPath)
    .map((p) => { try { return readFileSync(p, 'utf8'); } catch { return ''; } })
    .join('\n');
}

export const DOD_VERIFIED_RE = /DoD[-\s]?(VERIFIED|✅|PASS|DONE)|VERIFIED LIVE/i;

export const NO_DOD_NEEDED_RE = /\b(?:WONTFIX|FAKE|STALE|PHANTOM|DUPLICATE|DUPE|SUPERSEDED|DROPPED)\b|USER[-\s]?DROPPED|(?:no|not)\s+DoD\s+(?:needed|required)|\bNO[-\s]?DOD(?:-NEEDED)?\b|DoD[-\s]?N\/A/i;

export const SCOPE_NARROWED_DOD_RE =
  /DoD-VERIFIED[ \t]{0,2}[(\[:][ \t]*[^)\]\n]{0,80}?(scope[ \t]*[=:]|scoped[ \t]+to|partial(ly)?\b|only[ \t]+(phase|part|the)\b|remaining\b|the rest\b)/i;

const DOD_WORD_G = /DoD[-\s]?(VERIFIED|✅|PASS|DONE|GATED|BLOCKED)|VERIFIED LIVE/gi;

export function lastDodWord(blk) {
  const header = String(blk).split('\n')[0];
  const hits = header.match(DOD_WORD_G);
  if (!hits || !hits.length) return null;
  const last = hits[hits.length - 1];
  return /GATED|BLOCKED/i.test(last) ? 'GATED' : 'VERIFIED';
}
export const lastDodWordIsVerified = (blk) => lastDodWord(blk) === 'VERIFIED';

const DOD_WORD_ONCE = new RegExp(DOD_WORD_G.source, 'i');
export const dodWordAnywhere = (blk) => DOD_WORD_ONCE.test(String(blk));

export const OBSERVE_UNTIL_RE = /observe[-\s]?until\s*~?\s*(20\d\d-\d\d-\d\d(?:T\d\d:\d\d:\d\dZ)?)/i;

const GATE_ANCHOR_RE = /gate-(observed|extended)-at=(20\d\d-\d\d-\d\dT\d\d:\d\d:\d\dZ)/gi;
function gateAnchorAudit(blockText) {
  const anchors = [];
  for (const m of String(blockText || '').matchAll(GATE_ANCHOR_RE)) {
    anchors.push({ kind: m[1].toLowerCase(), iso: m[2], ts: Date.parse(m[2]) });
  }
  if (!anchors.length) return { ok: false, reason: 'missing-anchor', anchors };
  anchors.sort((a, b) => a.ts - b.ts);
  const lastObservedIdx = anchors.map((a) => a.kind).lastIndexOf('observed');
  if (lastObservedIdx < 0) return { ok: false, reason: 'first-anchor-not-observed', anchors };
  const episode = anchors.slice(lastObservedIdx);
  const first = episode[0];
  const last = episode[episode.length - 1];
  if (episode.filter((a) => a.kind === 'extended').length > 1) return { ok: false, reason: 'more-than-one-change', anchors, episode, first, last };
  if (last.ts - first.ts > 12 * 3600 * 1000) return { ok: false, reason: 'total-span>12h', anchors, episode, first, last };
  for (let i = 1; i < episode.length; i++) {
    if (episode[i].ts - episode[i - 1].ts > 12 * 3600 * 1000) {
      return { ok: false, reason: 'single-step>12h', anchors, episode, prev: episode[i - 1], current: episode[i] };
    }
  }
  return { ok: true, anchors, episode, first, last };
}

export function classifyDodLadder(blockText, ageHours) {
  const blk = String(blockText || '');
  if (isDodFailedDialectDrift(blk)) return { tag: 'FAILED', anchorErr: 'missing-anchor' };
  if (isDodFailed(blk)) {
    const anchors = dodFailedAnchors(blk)
      .map((iso) => Date.parse(iso)).filter((t) => !Number.isNaN(t)).sort((a, b) => a - b);
    if (!anchors.length) return { tag: 'FAILED', anchorErr: 'missing-anchor' };
    const last = anchors[anchors.length - 1];
    return { tag: 'FAILED', lastFailedAt: new Date(last).toISOString().replace(/\.\d{3}Z$/, 'Z'), ageH: (Date.now() - last) / 3600000 };
  }
  if (lastDodWordIsVerified(blk)) return { tag: 'VERIFIED' };
  const hdr = String(blk).split('\n')[0];
  const untilM = hdr.match(OBSERVE_UNTIL_RE);
  const untilFuture = untilM && Date.parse(untilM[1]) > Date.now();
  const untilPast = untilM && Date.parse(untilM[1]) <= Date.now();
  if (untilPast) return { tag: 'OVERDUE_DATE', until: untilM[1] };
  const hasGatedReason = /DoD[-\s]?(GATED|BLOCKED)[^\n]{6,}/i.test(hdr);
  if (untilFuture) {
    const audit = gateAnchorAudit(blk);
    if (!audit.ok) return { tag: 'OVERDUE_GATE_UNDATED', ageH: ageHours != null ? ageHours : null, ttlH: 24, gateReason: audit.reason };
    return { tag: 'GATED', until: untilM[1], gateAnchors: audit.anchors };
  }
  for (const line of blk.split('\n')) {
    if (!/DoD[-\s]?(GATED|BLOCKED)/i.test(line)) continue;
    const w = line.match(/merge-order:wave:(R-[a-z0-9-]+)/i);
    if (w) return { tag: 'GATED', wave: w[1] };
  }
  if (hasGatedReason) {
    const hdr = blk.split('\n')[0];
    const ttlH = ttlHoursFor(hdr);
    if (ageHours != null && ageHours > ttlH) return { tag: 'OVERDUE_GATE_UNDATED', ageH: ageHours, ttlH };
    const audit = gateAnchorAudit(blk);
    if (!audit.ok) return { tag: 'OVERDUE_GATE_UNDATED', ageH: ageHours != null ? ageHours : null, ttlH: 24, gateReason: audit.reason };
    return { tag: 'GATED', until: null, ttlH, ageH: ageHours != null ? ageHours : null, gateAnchors: audit.anchors };
  }
  const hasPending = /DoD[-\s]?pending|DoD[-\s]?awaiting|pending\s?(deploy|verif|walk|Playwright|observation)/i.test(blk);
  if (hasPending) return { tag: 'OVERDUE_PENDING', ageH: ageHours != null ? ageHours : null };
  return { tag: 'NO_DOD' };
}

export function isGatedOrObserving(block, now = Date.now()) {
  const b = String(block || '');
  if (isGated(b.split('\n')[0])) return true;
  const v = classifyDodLadder(b, null);
  return v.tag === 'GATED' && !!v.until && Date.parse(v.until) > now;
}

export const SELF_DONE_RE = /ARCHIVE-READY|ready to archive|\bfully DONE\b|wave\s+COMPLETE|DoD\s*(?:complete|done)\b/i;

export function ownSlugOf(headerOrName) {
  const m = String(headerOrName).match(/R-[a-z0-9-]+/i);
  return m ? m[0].toLowerCase() : '';
}

export function ledgerRowMatchesCard(cardHeader, row) {
  const own = ownSlugOf(cardHeader);
  if (!own) return false;
  const r = row || {};
  if (ownSlugOf(r.card || '') === own) return true;
  if (ownSlugOf(r.plan || '') === own) return true;
  if (String(r.card || '').trim() || String(r.plan || '').trim()) return false;
  const base = String(r.file || '').split(/[\\/]/).pop();
  const key = [r.plan, r.card, base].map((x) => String(x || '')).join(' ').toLowerCase();
  if (!key.trim()) return false;
  const toks = own.split(/[^a-z0-9]+/).filter((x) => x.length >= 4);
  if (toks.length < 2) return false;
  return toks.filter((x) => key.includes(x)).length >= 2;
}

export function selfDeclaredCompletion(bodyText, ownSlug) {
  const own = String(ownSlug || '').toLowerCase();
  const lines = String(bodyText).split('\n');
  for (const line of lines) {
    if (!SELF_DONE_RE.test(line)) continue;
    const mentioned = [...line.matchAll(/\[\[(R-[a-z0-9-]+)\]\]|\bR-[a-z0-9-]{4,}\b/gi)]
      .map((m) => (m[1] || m[0]).replace(/[[\]]/g, '').toLowerCase());
    if (mentioned.length && !mentioned.includes(own)) continue;
    return true;
  }
  return false;
}

export function ownedPRsIn(headerLine) {
  const scrubbed = String(headerLine || '')
    .replace(/`[^`]*`/g, ' ')
    .replace(/blocked-by=\S+/g, ' ');
  return [...new Set(
    [...scrubbed.matchAll(/(?:PR|MERGED)[\s*_~]{0,4}#(\d+)\b/g)].map((m) => Number(m[1])),
  )].filter((n) => Number.isFinite(n) && n > 0);
}

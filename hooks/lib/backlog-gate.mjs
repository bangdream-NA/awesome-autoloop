

const RESOLVED_TOKENS = /^(none|resolved|cleared|n\/a)$/i;

export function blockedByTokens(headerLine) {
  const head = String(headerLine || '').split('\n')[0];
  const re = /(?:[·;,]|\[gate\s*=)\s*\**\s*blocked-by=([a-z0-9:.#_/-]+)\**\s*(?:·|\]|\*\*|;|,|$)/gi;
  return [...head.matchAll(re)].map((m) => m[1]);
}

export function isGated(headerLine) {
  const all = blockedByTokens(headerLine);
  if (!all.length) return false;
  return !RESOLVED_TOKENS.test(all[all.length - 1]);
}

export function liveBlocker(headerLine) {
  const all = blockedByTokens(headerLine);
  if (!all.length) return null;
  const last = all[all.length - 1];
  return RESOLVED_TOKENS.test(last) ? null : last;
}

export function waveGateIsLive(waveSlug, openSlugs) {
  const want = String(waveSlug || '').trim().toLowerCase();
  if (!want) return true;
  const set = openSlugs instanceof Set ? openSlugs : new Set(openSlugs || []);
  if (!set.size) return true;
  return set.has(want);
}

export function priorityOf(headerLine) {
  const head = String(headerLine || '').split('\n')[0];
  const m = head.match(/·[^·]*\bP([0-3])\b(?:[^·]*·|[^·]*$)/u);
  return m ? Number(m[1]) : null;
}

export function effectivePriorityMap(cards) {
  const list = (Array.isArray(cards) ? cards : []).map((c) => {
    const header = String((c && c.header) || '');
    return {
      key: String((c && c.name) || header),
      header,
      base: priorityOf(header),
      ownsPr: (header.match(/\bPR\s+#(\d{2,5})\b/) || [])[1] || null,
      ownSlug: (header.match(/\b(R-[a-z0-9][a-z0-9-]{4,})/) || [])[1] || null,
      waitsPr: (header.match(/blocked-by=merge-order:pr#(\d{2,5})/i) || [])[1] || null,
      waitsWave: (header.match(/blocked-by=merge-order:wave:(R-[a-z0-9][a-z0-9-]*)/i) || [])[1] || null,
    };
  });

  const eff = new Map(list.map((c) => [c.key, c.base]));
  const better = (a, b) => (a == null ? b : b == null ? a : Math.min(a, b));

  for (let round = 0; round < list.length + 1; round += 1) {
    let changed = false;
    for (const waiter of list) {
      const wTier = eff.get(waiter.key);
      if (wTier == null) continue;
      if (!waiter.waitsPr && !waiter.waitsWave) continue;
      for (const target of list) {
        const isTarget = (waiter.waitsPr && target.ownsPr === waiter.waitsPr)
          || (waiter.waitsWave && target.ownSlug
              && target.ownSlug.toLowerCase() === waiter.waitsWave.toLowerCase());
        if (!isTarget || target.key === waiter.key) continue;
        const next = better(eff.get(target.key), wTier);
        if (next !== eff.get(target.key)) { eff.set(target.key, next); changed = true; }
      }
    }
    if (!changed) break;
  }
  return eff;
}

export const PRIORITY_TTL_HOURS = { 0: 4, 1: 24, 2: 72, 3: 168 };

export function ttlHoursFor(headerLine) {
  const p = priorityOf(headerLine);
  return PRIORITY_TTL_HOURS[p === null ? 3 : p];
}


export const OPEN_STATUSES = ['QUEUED', 'IN-DEV', 'REVIEW'];

export function statusOf(headerLine) {
  const m = String(headerLine || '').match(/^###\s*\[([A-Z-]+)\]/);
  return m ? m[1] : null;
}



export const GATE_BRACKET_RE = /\[\s*gate\s*[=:]\s*[^\]]*\]/gi;
export function stripGateBracket(text) {
  return String(text).replace(GATE_BRACKET_RE, '');
}

export const GATE_BLOCKER_TOKEN_RE = /SEQUENCE-AFTER|blocked-by=|overlap:pr#/i;

export const GATE_TOKEN_RE = /^(merge-order:pr#\d+|merge-order:wave:R-[a-z0-9-]+|user)$/;

export function mergeOrderWave(text) {
  const m = String(text || '').match(/merge-order:wave:(R-[a-z0-9-]+)/i);
  return m ? m[1] : null;
}

export const GATE_TOKEN_HELP = 'merge-order:pr#<N>  ·  merge-order:wave:<R-slug> (the named card must be OPEN)  ·  user (must carry asked-at=<ISO Z> on the same line)';

export function hasAskedAt(headerLine) {
  return /·\s*asked-at=20\d\d-\d\d-\d\dT\d\d:\d\d:\d\dZ/i.test(String(headerLine || '').split('\n')[0]);
}

export const LEGACY_GATE_TOKEN_RE =
  /^(pr#\d+|until:20\d\d-\d\d-\d\d|user|server-op|overlap:pr#\d+|wave-order:P[0-3]-tier-not-landed|lead-verify|lead-verification|premise-unproven|upstream-packaging|gating-dependency:.*)$/;



export function dodFailedAnchors(blockText) {
  return [...String(blockText || '').matchAll(/dod-failed-at=(20\d\d-\d\d-\d\dT\d\d:\d\d:\d\dZ)/gi)]
    .map((m) => m[1]).sort();
}

export function hasPassEvidenceAfter(blockText, sinceIso) {
  const since = Date.parse(sinceIso);
  if (!Number.isFinite(since)) return false;
  for (const m of String(blockText || '').matchAll(/dod-failed-cleared-at=(20\d\d-\d\d-\d\dT\d\d:\d\d:\d\dZ)/gi)) {
    const t = Date.parse(m[1]);
    if (Number.isFinite(t) && t >= since) return true;
  }
  return false;
}

export function isDodFailed(blockText) {
  const anchors = dodFailedAnchors(blockText);
  if (!anchors.length) return false;
  return !hasPassEvidenceAfter(blockText, anchors[anchors.length - 1]);
}

export function isDodFailedDialectDrift(blockText) {
  const blk = String(blockText || '');
  if (!blk.split('\n').some(assertsLiveDodFailure)) return false;
  return dodFailedAnchors(blk).length === 0;
}

function assertsLiveDodFailure(line) {
  const raw = String(line || '');
  if (/\b(?:cleared|released|resolved|fixed)\b/i.test(raw)) return false;
  for (const seg of raw.split(/·|\*\*|^\s*[-*]\s+/m)) {
    const s = seg.replace(/^[\s*_>`]+/, '').replace(/^(?:[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}️]\s*)+/u, '').replace(/^[\s*_]+/, '');
    if (/^DoD[-\s]?FAILED(?::|\s+(?:LOCK|CARD|LOCKED))[^\n]{6,}/i.test(s)) return true;
  }
  return false;
}



export function mergeOrderGateOnHeader(boardText, header) {
  const hdr = String(header || '');
  const board = String(boardText || '');
  if (!hdr) return '';
  const b = liveBlocker(hdr);
  if (!b || !/^merge-order:/.test(b)) return '';

  const mPr = /^merge-order:pr#(\d+)$/.exec(b);
  if (mPr) {
    const want = Number(mPr[1]);
    for (const other of board.split(/^### \[/m).slice(1)) {
      const oh = `### [${other.split('\n')[0]}`;
      if (new RegExp(`MERGED\\s*#${want}\\b`).test(oh)) return '';
      if (!new RegExp(`PR\\s*#${want}\\b`).test(oh)) continue;
      if (OPEN_STATUSES.includes(statusOf(oh))) return b;
    }
    return '';
  }

  const mWave = /^merge-order:wave:(.+)$/.exec(b);
  if (mWave) {
    const want = mWave[1].trim();
    for (const other of board.split(/^### \[/m).slice(1)) {
      const oh = `### [${other.split('\n')[0]}`;
      if (slugOf(oh) === want && OPEN_STATUSES.includes(statusOf(oh))) return b;
    }
    return '';
  }
  return '';
}

export function slugOf(headerLine) {
  const h = String(headerLine || '').split('\n')[0];
  const m = h.match(/^###\s*\[[^\]]*\]\s*(?:[^·\n]{0,40}·\s*)?(R-[A-Za-z0-9-]+)/);
  return m ? m[1] : null;
}


const REMEDY_FOR_RE =
  /(?:[·;,]|\[gate\s*=)\s*\**\s*dod-remedy-for=(R-[A-Za-z0-9-]+)\**\s*(?:·|\]|\*\*|;|,|$)/gi;
const REMEDY_TRACKS_RE =
  /(?:[·;,]|\[gate\s*=)\s*\**\s*dod-remedy-tracks=((?:R-[A-Za-z0-9-]+)(?:,R-[A-Za-z0-9-]+)*)\**\s*(?:·|\]|\*\*|;|$)/gi;

export function dodRemedyFor(headerLine) {
  const head = String(headerLine || '').split('\n')[0];
  const all = [...head.matchAll(REMEDY_FOR_RE)].map((m) => m[1]);
  return all.length ? all[all.length - 1] : null;
}

export function dodRemedyTracks(headerLine) {
  const head = String(headerLine || '').split('\n')[0];
  const all = [...head.matchAll(REMEDY_TRACKS_RE)].map((m) => m[1]);
  if (!all.length) return [];
  return all[all.length - 1].split(',').map((s) => s.trim()).filter(Boolean);
}

export function isDodRemedyTrack(headerLine, cards) {
  const src = dodRemedyFor(headerLine);
  const me = slugOf(headerLine);
  if (!src || !me) return false;
  const source = (cards || []).find((c) => slugOf(c.header) === src);
  if (!source) return false;
  if (!isDodFailed(source.block)) return false;
  return dodRemedyTracks(source.header).includes(me);
}

export const STAGES = ['new', 'planning', 'plan-ready', 'plan-review', 'plan-ok', 'arch', 'arch-ok', 'dev', 'pr', 'review', 'merged'];

export function stageOf(headerLine) {
  const m = String(headerLine || '').split('\n')[0].match(/(?:^|[\s·|])stage=([a-z-]+)/i);
  const s = m ? m[1].toLowerCase() : null;
  return s && STAGES.includes(s) ? s : null;
}

export const STAGE_FOR_ROLE = {
  planner: ['new', 'planning'],
  'plan-reviewer': ['plan-ready', 'plan-review'],
  'uiux-designer': ['plan-ok'],
  designer: ['plan-ok'],
  architect: ['plan-ok', 'arch'],
  developer: ['arch-ok', 'dev'],
  'code-reviewer': ['pr', 'review'],
};

export const HOLDER_ROLE = Object.fromEntries(
  Object.entries(STAGE_FOR_ROLE).flatMap(([r, sts]) => (sts.length > 1 ? [[sts[1], r]] : [])),
);



export const NEXT_BY_STAGE = {
  new: 'planner', planning: 'planner', 'plan-ready': 'plan-reviewer', 'plan-review': 'plan-reviewer',
  'plan-ok': 'architect',
  arch: 'architect', 'arch-ok': 'developer', dev: 'developer',
  pr: 'code-reviewer', review: 'code-reviewer',
};

export const NEXT_AFTER_DELIVERY = {
  new: 'planner', planning: 'plan-reviewer', 'plan-ready': 'plan-reviewer',
  'plan-review': 'architect',
  'plan-ok': 'architect',
  arch: 'developer', 'arch-ok': 'developer', dev: 'code-reviewer',
  pr: 'code-reviewer',
  review: '',
};

export function stageTableDrift() {
  const bad = [];
  const owns = (role, stage) => Array.isArray(STAGE_FOR_ROLE[role]) && STAGE_FOR_ROLE[role].includes(stage);
  for (const [name, tbl] of [['NEXT_BY_STAGE', NEXT_BY_STAGE], ['NEXT_AFTER_DELIVERY', NEXT_AFTER_DELIVERY]]) {
    for (const st of Object.keys(tbl)) {
      if (!STAGES.includes(st)) bad.push(`${name}: stage \`${st}\` is not in STAGES`);
    }
    for (const [st, role] of Object.entries(tbl)) {
      if (role === '') continue;
      if (!Object.prototype.hasOwnProperty.call(STAGE_FOR_ROLE, role)) {
        bad.push(`${name}[${st}] = \`${role}\`, and STAGE_FOR_ROLE has no such role`);
      }
    }
  }
  for (const [st, role] of Object.entries(NEXT_BY_STAGE)) {
    if (!owns(role, st)) bad.push(`NEXT_BY_STAGE[${st}] = \`${role}\`, but STAGE_FOR_ROLE['${role}'] does not contain \`${st}\``);
  }
  for (const [st, role] of Object.entries(NEXT_AFTER_DELIVERY)) {
    if (role === '') continue;
    const sts = STAGE_FOR_ROLE[role];
    if (!Array.isArray(sts) || !sts.length) continue;
    const here = STAGES.indexOf(st);
    const earliest = Math.min(...sts.map((s) => STAGES.indexOf(s)).filter((i) => i >= 0));
    if (earliest < here) {
      bad.push(`NEXT_AFTER_DELIVERY[${st}] = \`${role}\`, but its earliest dispatch stage `
        + `\`${STAGES[earliest]}\` sorts **before** \`${st}\` => that dispatches backwards`);
    }
  }
  return bad;
}

export const ROLE_BY_AGENT_PREFIX = [
  ['planrev', 'plan-reviewer'],
  ['planner', 'planner'],
  ['codereview', 'code-reviewer'],
  ['uiux', 'uiux-designer'],
  ['designer', 'uiux-designer'],
  ['arch', 'architect'],
  ['dev', 'developer'],
];

export function lastDispatchedRole(blockText) {
  const logs = String(blockText || '').split(/\r?\n/).filter((l) => /^-\s*log:/.test(l));
  for (let i = logs.length - 1; i >= 0; i--) {
    const m = logs[i].match(/·\s*([a-z]+)[a-z0-9-]*-r?\d/i);
    if (!m) continue;
    const head = m[1].toLowerCase();
    const hit = ROLE_BY_AGENT_PREFIX.find(([p]) => head.startsWith(p));
    if (hit) return hit[1];
  }
  return '';
}

export const STAGE_AFTER_DISPATCH = {
  planner: 'planning',
  'plan-reviewer': 'plan-review',
  'uiux-designer': 'plan-ok',
  designer: 'plan-ok',
  architect: 'arch',
  developer: 'dev',
  'code-reviewer': 'review',
};

export function stageLagsLastDispatch(header, block, role) {
  const prev = lastDispatchedRole(block);
  const need = prev ? STAGE_AFTER_DISPATCH[prev] : '';
  const cur = stageOf(header) || '';
  const iCur = STAGES.indexOf(cur);
  const iNeed = STAGES.indexOf(need);
  if (!need || iCur < 0 || iNeed < 0 || iCur >= iNeed) return null;
  if (role && prev !== String(role).toLowerCase()) return null;
  return { prev, need, cur };
}

export function branchDispatchRefused(branch, boardText) {
  if (!branch || !boardText) return false;
  const blocks = String(boardText).split(/^### \[/m).slice(1).map((b) => '### [' + b);
  const cards = blocks.map((b) => ({ header: b.split('\n')[0], block: b }));

  const locked = cards.filter((c) => isDodFailed(c.block));
  if (!locked.length) return false;

  const esc = String(branch).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const mine = cards.find((c) => new RegExp('^-\\s*aliases:.*(?:^|[\\s,·])' + esc + '(?:$|[\\s,·])', 'm').test(c.block));
  if (!mine) return false;

  if (isDodFailed(mine.block)) return false;
  if (isDodRemedyTrack(mine.header, cards)) return false;
  return true;
}

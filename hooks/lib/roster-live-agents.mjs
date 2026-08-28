import { readFileSync, existsSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { HOLDER_ROLE } from './backlog-gate.mjs';
import { repoOfAnyPath, repoOfBoardPath, sessionProject } from './is-autoloop-lead.mjs';

const teamsDir = () => process.env.RLA_TEAMS_DIR || join(process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude'), 'teams');

function claimedConfigs(sid) {
  const dir = teamsDir();
  let entries = [];
  try { entries = readdirSync(dir); } catch { return null; }
  const out = [];
  for (const d of entries) {
    const f = join(dir, d, 'config.json');
    if (!existsSync(f)) continue;
    try {
      const j = JSON.parse(readFileSync(f, 'utf8'));
      if (j.leadSessionId === sid || j.prevLeadSessionId === sid) out.push(f);
    } catch {  }
  }
  return out;
}

export function teamConfigsFor(sid = process.env.CLAUDE_CODE_SESSION_ID || '') {
  if (!sid) return [];
  const claimed = claimedConfigs(sid);
  if (claimed === null) return [];
  if (claimed.length) return claimed;
  const one = idSplitFallback(sid);
  return one ? [one] : [];
}

export function resolveTeamConfig(sid = process.env.CLAUDE_CODE_SESSION_ID || '') {
  const all = teamConfigsFor(sid);
  return all.length ? all[all.length - 1] : null;
}

function idSplitFallback(sid) {
  const dir = teamsDir();
  let entries = [];
  try { entries = readdirSync(dir); } catch { return null; }
  const FRESH_MS = 24 * 60 * 60 * 1000;
  const fresh = [];
  for (const d of entries) {
    const f = join(dir, d, 'config.json');
    if (!existsSync(f)) continue;
    try {
      if (Date.now() - statSync(f).mtimeMs <= FRESH_MS) fresh.push({ d, f });
    } catch {  }
  }
  const head = sid.slice(0, 8);
  const byName = fresh.find(({ d }) => d.replace(/^session-/, '').slice(0, 8) === head);
  if (byName) return byName.f;
  return fresh.length === 1 ? fresh[0].f : null;
}

// An absolute path in free text, on either platform. The POSIX branch is guarded by a lookbehind so
// it starts a path only where one can start: `and/or`, `~/.claude/…` and `https://host/x` all carry
// a slash and none of them is a path this should probe.
const ABS_PATH_RE = /(?:\b[A-Za-z]:[\\/]|(?<![\w.\-/:~])\/)[^\s"'`)\]},;:!?()]+/g;
const REPO_CACHE = new Map();
const MAX_PATH_PROBES = 8;

function repoOfCached(p) {
  if (REPO_CACHE.has(p)) return REPO_CACHE.get(p);
  let r = null;
  try { r = repoOfBoardPath(p) || repoOfAnyPath(p); } catch { r = null; }
  REPO_CACHE.set(p, r);
  return r;
}


export function memberProject(m) {
  const paths = [...new Set((String((m && m.prompt) || '').match(ABS_PATH_RE) || [])
    .map((s) => s.replace(/\\/g, '/')))];
  let probes = 0;
  for (const p of paths) {
    if (probes >= MAX_PATH_PROBES) break;
    probes += 1;
    const r = repoOfCached(p);
    if (r) return r;
  }
  return null;
}

function ofThisProject(members, sid) {
  let mine = null;
  try { mine = sessionProject(sid ? { session_id: sid } : {}); } catch { mine = null; }
  if (!mine) return members;
  return members.filter((m) => {
    const p = memberProject(m);
    return !p || p === mine;
  });
}

function membersFor(sid) {
  const cfgs = teamConfigsFor(sid);
  if (!cfgs.length) return null;
  const out = [];
  const seen = new Set();
  let readAny = false;
  for (const cfg of cfgs) {
    let members;
    try { members = JSON.parse(readFileSync(cfg, 'utf8')).members; } catch { continue; }
    if (!Array.isArray(members)) continue;
    readAny = true;
    for (const m of members) {
      if (!m || m.agentType === 'team-lead' || m.name === 'team-lead') continue;
      const key = String(m.name || m.agentId || '');
      if (seen.has(key)) continue;
      seen.add(key);
      out.push(m);
    }
  }
  if (!readAny) return null;
  return ofThisProject(out, sid);
}

export function liveAgentNames(sid) {
  const members = membersFor(sid);
  if (!members) return null;
  return members.map((m) => m.name || m.agentId || '?');
}

export function liveAgentMembers(sid) {
  const members = membersFor(sid);
  if (!members) return null;
  return members.map((m) => ({ name: String(m.name || m.agentId || ''), agentType: String(m.agentType || ''), prompt: String(m.prompt || ''), joinedAt: Number(m.joinedAt) || 0 }));
}

export function rosterFilteredHolders(holders, liveNames) {
  const hs = Array.isArray(holders) ? holders : [];
  if (!Array.isArray(liveNames)) return hs;
  const live = new Set(liveNames);
  return hs.filter((h) => live.has(h));
}

const namesPr = (hay, prNumber) => new RegExp(`(?<!\\d)${Number(prNumber)}(?!\\d)`).test(hay);

export function rosterHoldsCard({ members, stage, prNumber } = {}) {
  if (!Array.isArray(members)) return false;
  const role = HOLDER_ROLE[String(stage || '')];
  if (!role) return false;
  const byRole = members.filter((m) => m && m.agentType === role);
  if (!byRole.length) return false;
  const hasPr = prNumber !== undefined && prNumber !== null && String(prNumber) !== '';
  if (!hasPr) return true;
  return byRole.some((m) => namesPr(`${m.name || ''} ${m.prompt || ''}`, prNumber));
}

export function waveOfAgentName(name) {
  const segs = String(name || '').toLowerCase().split('-');
  return segs.length >= 2 ? segs[1] : '';
}

export function holdersOfCardByWave({ members, cardBlock } = {}) {
  if (!Array.isArray(members)) return [];
  const alias = (String(cardBlock || '').match(/^-\s*aliases\s*:\s*(.+)$/m) || [])[1] || '';
  if (!alias) return [];
  const hay = alias.toLowerCase();
  return members.filter((m) => {
    if (!m || !m.name || m.name === 'team-lead') return false;
    const w = waveOfAgentName(m.name);
    return w.length >= 4 && hay.includes(w);
  });
}

export function rosterHoldsCardByWave(args) {
  return holdersOfCardByWave(args).length > 0;
}

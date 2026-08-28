#!/usr/bin/env node
import { readFileSync, writeFileSync, readdirSync, statSync, existsSync, appendFileSync } from 'node:fs';
import path from 'node:path';
import { homeDir, sidOf, sessionProject } from './lib/is-autoloop-lead.mjs';
import { memberProject } from './lib/roster-live-agents.mjs';

const HOME = homeDir();
const TEAMS = process.env.RTO_TEAMS_DIR || path.join(HOME, '.claude/teams');
const STATE = process.env.RTO_STATE_DIR || path.join(HOME, '.claude/hooks/.state');
const SIDLOG = path.join(STATE, 'stop-stdin-sids.log');
const FRESH_H = 24;

const args = process.argv.slice(2);
const flag = (n) => { const i = args.indexOf(n); return i >= 0 ? (args[i + 1] || '') : ''; };
const FIX = args.includes('--fix');
const AUTO = args.includes('--auto');

const sidLines = existsSync(SIDLOG)
  ? readFileSync(SIDLOG, 'utf8').split(/\r?\n/).filter(Boolean)
  : [];
const knownSids = new Set(sidLines.map((l) => l.split(/\s+/)[1]).filter(Boolean));

const MY_SID = sidOf({});
const MY_PROJECT = (() => { try { return sessionProject(MY_SID ? { session_id: MY_SID } : {}); } catch { return null; } })();

function ownerSessionAliveH(teamDir) {
  const head = String(teamDir).replace(/^session-/, '');
  if (!/^[0-9a-f]{8}/i.test(head)) return null;
  const root = path.join(homeDir(), '.claude', 'projects');
  let projects = [];
  try { projects = readdirSync(root); } catch { return null; }
  for (const p of projects) {
    let files = [];
    try { files = readdirSync(path.join(root, p)); } catch { continue; }
    for (const f of files) {
      if (!f.toLowerCase().startsWith(head.toLowerCase()) || !f.endsWith('.jsonl')) continue;
      try { return (Date.now() - statSync(path.join(root, p, f)).mtimeMs) / 3600000; } catch {  }
    }
  }
  return null;
}

function teamProject(cfgPath) {
  let j = {};
  try { j = JSON.parse(readFileSync(cfgPath, 'utf8')); } catch { return null; }
  for (const m of j.members || []) {
    if (!m || m.agentType === 'team-lead' || m.name === 'team-lead') continue;
    const p = memberProject(m);
    if (p) return p;
  }
  return null;
}

const teams = [];
try {
  for (const d of readdirSync(TEAMS)) {
    const cfg = path.join(TEAMS, d, 'config.json');
    if (!existsSync(cfg)) continue;
    const st = statSync(cfg);
    const ageH = (Date.now() - st.mtimeMs) / 3600000;
    let j = {};
    try { j = JSON.parse(readFileSync(cfg, 'utf8')); } catch { continue; }
    teams.push({ dir: d, cfg, ageH, lead: String(j.leadSessionId || ''), members: (j.members || []).length, ownerAliveH: ownerSessionAliveH(d), proj: null });
  }
} catch (e) { console.error('cannot read teams dir:', String(e)); process.exit(1); }

const splitCandidates = () => teams.filter((t) => t.ageH < FRESH_H).filter((t) => {
  if (!MY_SID || !t.lead) return false;
  if (t.lead.startsWith(MY_SID) || MY_SID.startsWith(t.lead.slice(0, 8))) return false;
  if (t.ownerAliveH !== null && t.ownerAliveH < 24) return false;
  if (MY_PROJECT) {
    if (t.proj === null) t.proj = teamProject(t.cfg);
    if (t.proj && t.proj !== MY_PROJECT) return false;
  }
  return true;
});

if (!FIX) {
  console.log('=== reconcile-team-owner: DIAGNOSE ===');
  console.log(`my sid   : ${MY_SID || '(UNKNOWN — no stdin/transcript/CLAUDE_CODE_SESSION_ID)'}`);
  console.log(`my project: ${MY_PROJECT || '(unknown — not a lead of any project per the marker)'}`);
  console.log(`stdin-sid log (${SIDLOG}): ${sidLines.length} lines — for cross-checking, NOT the source of identity (several windows share it)`);
  for (const l of sidLines.slice(-5)) console.log('  ', l);
  if (!sidLines.length) console.log('  (empty — end this turn once so a Stop records YOUR sid, then re-run)');
  console.log(`\nteams fresher than ${FRESH_H}h:`);
  const fresh = teams.filter((t) => t.ageH < FRESH_H);
  for (const t of fresh) {
    if (t.proj === null) t.proj = teamProject(t.cfg);
    console.log(`   ${t.dir}  lead=${t.lead.slice(0, 8)}…  members=${t.members}  mtime-${t.ageH.toFixed(1)}h  proj=${t.proj || '?'}`);
  }
  if (!fresh.length) console.log('   (none)');
  const split = splitCandidates();
  if (MY_SID && split.length) {
    console.log(`\nID-SPLIT candidates (fresh team, same project, whose lead != my sid ${MY_SID.slice(0, 8)}…):`);
    for (const t of split) console.log(`   node <hooks>/reconcile-team-owner.mjs --fix --team ${t.dir} --to ${MY_SID}`);
    console.log('ONLY run the --fix from the session that actually drives that team.');
  }
  process.exit(0);
}

let teamDir = flag('--team');
let to = flag('--to');
if (AUTO && !teamDir && !to) {
  if (!MY_SID) { console.log('auto: cannot tell which session I am — nothing to align'); process.exit(0); }
  const split = splitCandidates();
  if (split.length === 0) { console.log('auto: no ID-SPLIT'); process.exit(0); }
  if (split.length > 1) {
    console.log(`auto: ${split.length} split candidates — REFUSING to guess which team is mine. Run --fix explicitly:`);
    for (const t of split) console.log(`   node <hooks>/reconcile-team-owner.mjs --fix --team ${t.dir} --to ${MY_SID}`);
    process.exit(0);
  }
  teamDir = split[0].dir; to = MY_SID;
  console.log(`auto: single ID-SPLIT candidate ${teamDir} (proj=${split[0].proj || '?'}) → aligning to ${to.slice(0, 8)}…`);
}
if (!teamDir || !to) { console.error('need --team session-XXXX --to <sid>'); process.exit(1); }
if (!knownSids.has(to)) {
  console.error(`REFUSED: --to ${to} was never observed in ${SIDLOG} — end the turn once (a Stop records your sid) and use the exact observed value. Aligning to an unobserved id would just re-split ownership.`);
  process.exit(1);
}
const t = teams.find((x) => x.dir === teamDir);
if (!t) { console.error(`REFUSED: team dir ${teamDir} not found under ${TEAMS}`); process.exit(1); }
if (t.lead === to) { console.log(`no-op: ${teamDir} leadSessionId already ${to}`); process.exit(0); }
if (MY_PROJECT) {
  const tp = teamProject(t.cfg);
  if (tp && tp !== MY_PROJECT) {
    console.error(`REFUSED: ${teamDir} works on ${tp} but this session leads ${MY_PROJECT} — aligning it would hand another project's team to me. If that is really what you want, fix the marker first.`);
    process.exit(1);
  }
}

const j = JSON.parse(readFileSync(t.cfg, 'utf8'));
j.prevLeadSessionId = j.leadSessionId || '';
j.leadSessionId = to;
writeFileSync(t.cfg, JSON.stringify(j, null, 2), 'utf8');
try { appendFileSync(path.join(STATE, 'team-owner-reconcile.log'), `${new Date().toISOString()} ${teamDir}: ${j.prevLeadSessionId} -> ${to}\n`); } catch {  }
console.log(`aligned: ${teamDir} leadSessionId ${j.prevLeadSessionId.slice(0, 8)}… -> ${to.slice(0, 8)}… (prev kept as prevLeadSessionId). roster-tripwire will now see this team as yours.`);

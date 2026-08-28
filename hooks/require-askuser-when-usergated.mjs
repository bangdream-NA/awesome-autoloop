#!/usr/bin/env node
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, dirname } from 'node:path';
import { isGated, priorityOf, effectivePriorityMap, statusOf } from './lib/backlog-gate.mjs';
import { lastAssistantText, stripQuoted, readTranscriptText } from './lib/transcript-last-assistant.mjs';
import { userPresenceFrom } from './lib/user-presence.mjs';
import { LANDED_RE } from './lib/landed-evidence.mjs';
import { autoLogOnDeny } from './lib/log-denial.mjs';
import { knownProjects, resolveRepo } from './lib/is-autoloop-lead.mjs';
autoLogOnDeny('require-askuser-when-usergated');

function read(fd) { try { return readFileSync(fd, 'utf8'); } catch { return ''; } }
let stdin = {};
try { stdin = JSON.parse(read(0) || '{}'); } catch { process.exit(0); }

const allow = () => { process.stdout.write('{}'); process.exit(0); };

let tpath = (typeof stdin.transcript_path === 'string' && stdin.transcript_path) || null;
if (!tpath) {
  const sid = stdin.session_id || '';
  if (!sid) allow();
  try {
    const projects = join(process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude'), 'projects');
    for (const d of readdirSync(projects)) {
      const c = join(projects, d, sid + '.jsonl');
      if (existsSync(c)) { tpath = c; break; }
    }
  } catch { allow(); }
}
if (!tpath) allow();

let lines = [];
{
  const { text, truncated } = readTranscriptText(tpath);
  lines = text.split('\n').filter(Boolean);
  if (truncated) process.stderr.write('[askuser-gate] transcript > string limit — read tail only\n');
}
if (!lines.length) allow();

const tail = lines.slice(-400);

const presenceTail = lines.slice(-4000);

const { present: userPresent } = userPresenceFrom(presenceTail);
if (!userPresent) allow();

const ASK_DELIVERED = /Your questions have been answered|"tool_use_id"[^\n]*"answers"\s*:/;
let lastAskIdx = -1;
for (let i = 0; i < tail.length; i += 1) {
  if (!/"name"\s*:\s*"AskUserQuestion"/.test(tail[i])) continue;
  for (let j = i; j < tail.length; j += 1) {
    if (ASK_DELIVERED.test(tail[j])) { lastAskIdx = Math.max(lastAskIdx, i); break; }
  }
}

const ALL_BOARDS = process.env.AAL_BACKLOG
  ? [{ root: dirname(dirname(process.env.AAL_BACKLOG)), board: process.env.AAL_BACKLOG }]
  : [
    ...knownProjects().map((r) => ({ root: r, board: join(r, '.claude', 'BACKLOG.md') })),
    ];
const isToolUse = (l) => /"type"\s*:\s*"tool_use"/.test(l);
const tailText = tail.filter(isToolUse).join('\n');
const norm = (s) => s.replace(/[\\/]+/g, '/').toLowerCase();
const hay = norm(tailText);
const forms = (root) => {
  const w = norm(root);
  const m = w.match(/^([a-z]):\/(.*)$/);
  return m ? [w, `/${m[1]}/${m[2]}`] : [w];
};
const sameRoot = (a, b) => norm(a).replace(/\/+$/, '') === norm(b).replace(/\/+$/, '');
const SEAM_ROOT = process.env.AAL_BACKLOG ? dirname(dirname(process.env.AAL_BACKLOG)) : null;
const SESSION_REPO = (SEAM_ROOT && !process.env.AAL_LEAD_REPO) ? SEAM_ROOT : resolveRepo(stdin);
const BOARDS = ALL_BOARDS.filter((p) => (SESSION_REPO
  ? sameRoot(p.root, SESSION_REPO)
  : forms(p.root).some((f) => hay.includes(f)))).map((p) => p.board);
if (!BOARDS.length) allow();
const parked = [];
for (const b of BOARDS) {
  let txt = '';
  try { txt = readFileSync(b, 'utf8'); } catch { continue; }
  const headers = txt.split(/\r?\n/).filter((l) => /^### \[/.test(l));
  const effMap = effectivePriorityMap(headers.map((h) => ({ name: h, header: h })));
  for (const line of headers) {
    const st = statusOf(line);
    const userTok = /·\s*blocked-by=user\b/i.test(line) && isGated(line);
    if (st === 'USER-GATED' || (['QUEUED', 'IN-DEV', 'REVIEW'].includes(st) && userTok)) {
      const nm = (line.match(/^### \[[^\]]+\]\s+([A-Za-z0-9._-]+)/) || [])[1];
      const own = priorityOf(line); const eff = effMap.get(line);
      const p = eff != null && (own == null || eff < own) ? eff : own;
      const lifted = p != null && own != null && p < own ? `←P${own}` : '';
      if (nm) parked.push(`${nm}${p !== null ? ` (P${p}${lifted})` : ''}`);
    }
  }
}
const OWNED_BY_USER = [
  'needs your authorisation', 'need you to authorise', 'awaiting your authorisation', 'your authorisation',
  'needs your approval', 'need you to approve', 'awaiting your approval', 'your approval', 'need your consent',
  'that one is yours', 'waiting for you to rule', 'awaiting your ruling', 'yours to decide', 'filed under you',
  'waiting for you to decide', 'you decide', 'your decision', 'for you to settle', 'waiting for you to come back and decide',
  'the user decides', 'awaiting the user', 'waiting on the user',
];
const DELEGATION_RE = new RegExp(
  '\\b(?:you|the user)\\b[^.;\\n]{0,6}\\b(?:decide|decides|rule|rules|call it|settle it|have the final say)\\b'
  + '|\\b(?:you|the user)\\b\\s+(?:to\\s+)?(?:approve|sign off|rule|settle|adjudicate)\\b'
  + '|\\b(?:need|needs|want|wait for|waiting for|ask|let)\\s+(?:you|the user)\\s+(?:to\\s+)?(?:approve|sign|decide|judge|choose|rule)\\b'
  + '|\\b(?:up to|your call|as you (?:prefer|like)|whatever you say)\\b'
  + '|\\b(?:for|by|handed to)\\s+(?:you|the user)\\s+to\\s+(?:decide|rule|judge|choose|approve|sign)\\b',
);
const NOT_DELEGATION_RE = new RegExp(
  '\\b(?:you|the user)\\s+(?:said|already|earlier|previously|had|were right)\\b'
  + '|\\bas\\s+(?:you|the user)\\s+(?:decided|ruled|said)\\b'
  + '|(?<!\\b(?:for|await|awaiting|ask|let)\\s)\\b(?:you|the user)\\s+(?:approved|signed off|decided|ruled|chose|agreed|authorised)\\b',
);
const PENDING_ASK_RE = /\b(?:wait(?:ing)? for|await(?:ing)?|need|needs|ask|let)\s+(?:you|the user)\b/i;
const proseHits = [];
{
  const txt = stripQuoted(lastAssistantText(stdin));
  const sentences = txt.split(/[.!?\n;]+/).filter((s) => s.trim());
  for (const s of sentences) {
    if (LANDED_RE.test(s) && !PENDING_ASK_RE.test(s)) continue;
    let hit = '';
    if (!NOT_DELEGATION_RE.test(s)) {
      for (const p of OWNED_BY_USER) if (s.includes(p)) { hit = p; break; }
    }
    if (!hit && DELEGATION_RE.test(s) && !NOT_DELEGATION_RE.test(s)) {
      hit = (s.match(DELEGATION_RE) || ['(shape: second person plus a deciding verb)'])[0];
    }
    if (hit && !proseHits.includes(hit)) proseHits.push(hit);
  }
}

let lastDelegIdx = -1;
if (proseHits.length) {
  for (let i = 0; i < tail.length; i += 1) {
    const l = tail[i];
    if (!/"type"\s*:\s*"text"/.test(l) && !/"text"\s*:/.test(l)) continue;
    if (/"name"\s*:\s*"AskUserQuestion"/.test(l)) continue;
    const hit = OWNED_BY_USER.some((p) => l.includes(p))
      || (DELEGATION_RE.test(l) && !NOT_DELEGATION_RE.test(l));
    if (hit) lastDelegIdx = i;
  }
}
const dischargedByLaterAsk = proseHits.length > 0 && lastAskIdx > lastDelegIdx;
if (dischargedByLaterAsk) proseHits.length = 0;
if (parked.length && lastAskIdx >= 0) parked.length = 0;

if (!parked.length && !proseHits.length) allow();

const proseNote = proseHits.length
  ? `\n\nThis turn ${proseHits.length} judgement(s) were called YOURS without being asked:` +
    `${proseHits.slice(0, 4).map((s) => `"${s}"`).join(' · ')}.` +
    `\nPick one: call AskUserQuestion in this same turn, or — if it is not theirs — change the sentence.`
  : '';

const parkedNote = parked.length
  ? `${parked.length} user-decision card(s) are parked — ` +
    `${parked.slice(0, 8).join(', ')}${parked.length > 8 ? ', …' : ''} — and `
  : '';

const askNote = lastAskIdx >= 0
  ? `this turn DID call AskUserQuestion, but that call came BEFORE the delegating sentence — an ` +
    `earlier question about something else does not discharge a later one. `
  : `this turn made NO AskUserQuestion call. `;
const reason =
  `BLOCKED: the user is present ⇒ ask in THIS turn with AskUserQuestion; do not park it.${parkedNote}${askNote}` +
  `\nBackground and consequences go INSIDE the dialog body, not in surrounding prose. Read the artifact first-hand before asking.` +
  `\nIf the card is not actually theirs ⇒ change its gate, rather than routing around this check.` + proseNote;

process.stdout.write(JSON.stringify({
  decision: 'block',
  reason,
}));
process.exit(0);

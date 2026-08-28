#!/usr/bin/env node
import { readFileSync, existsSync, readdirSync, statSync,
  openSync, readSync, closeSync, mkdirSync, writeFileSync } from 'node:fs';
import { autoLogOnDeny } from './lib/log-denial.mjs';
import { readTranscriptText } from './lib/transcript-last-assistant.mjs';
import { ownSlugOf } from './lib/backlog-grammar.mjs';
import { homeDir } from './lib/is-autoloop-lead.mjs';
autoLogOnDeny('require-wave-doc-read-before-dod-token');

function allow() { process.stdout.write('{}'); process.exit(0); }
let raw = '';
try { raw = readFileSync(0, 'utf8'); } catch { allow(); }
let payload;
try { payload = JSON.parse(raw); } catch { allow(); }

const tin = payload.tool_input || {};
const file = String(tin.file_path || '').replace(/\\/g, '/');
if (!/\.claude\/BACKLOG[^/]*\.md$/i.test(file)) allow();

const text = String(tin.content || tin.new_string || '');
if (!text) allow();

const TOKEN = /DoD-(?:VERIFIED|FAILED|GATED|OBSOLETE)\b/;
const headerHasToken = text.split(/\r?\n/).some((l) => l.startsWith('### ') && TOKEN.test(l));
if (!headerHasToken) allow();

{
  const OUTCOMES = [/DoD-VERIFIED/, /DoD-FAILED/, /DoD-GATED/];
  const badHeaders = text.split(/\r?\n/).filter((l) => l.startsWith('### ') && OUTCOMES.some((re) => re.test(l)))
    .map((l) => ({
      line: l,
      queued: /^###\s*\[QUEUED\]/.test(l) && TOKEN.test(l),
      noStage: !/\bstage=/.test(l) && TOKEN.test(l),
      conflict: OUTCOMES.filter((re) => re.test(l)).length > 1,
    }))
    .filter((h) => h.queued || h.noStage || h.conflict);
  if (badHeaders.length) {
    const h = badHeaders[0];
    const why = [h.queued ? 'the badge is `[QUEUED]` (work never started)' : null,
      h.noStage ? 'the line has no `stage=` at all (no record of getting anywhere)' : null,
      h.conflict ? 'the same line carries **several mutually exclusive outcome tokens** (walked / broke / only waiting on time — pick one)' : null,
    ].filter(Boolean).join(' + ');
    process.stdout.write(JSON.stringify({
      hookSpecificOutput: {
        hookEventName: 'PreToolUse',
        permissionDecision: 'deny',
        permissionDecisionReason:
          'BLOCKED: a completion token on a card that CANNOT have finished its DoD\n\n' +
          '  The line that was sampled:\n' +
          '    · ' + h.line.slice(0, 150) + '\n' +
          '    · contradiction: ' + why + '\n\n' +
          '  FIX, one of two:\n' +
          '    1. it really did finish ⇒ first move `stage=` to the state it actually reached (nine states: new -> … -> merged), then write the token\n' +
          '    2. it did not ⇒ do not write a completion token. The honest outcomes are: `DoD-FAILED` + `dod-failed-at=` ·\n' +
          '       `DoD-GATED: observe-until <date>` + `gate-observed-at=` · or write nothing and leave it open\n' +
          '  Changing only the badge without touching `stage=` does not pass — that just moves the contradiction.',
      },
    }));
    process.exit(0);
  }
}

const SEP = '(?:[\\\\/]|\\\\\\\\)';
const SPEC_RE = new RegExp(
  `docs${SEP}product-specs${SEP}R-[^"'\\s]*-(?:plan|architecture)\\.md`
  + `|\\.claude${SEP}reviews${SEP}[^"'\\s]*\\.md`, 'i');

function transcriptPath() {
  if (payload.transcript_path && existsSync(payload.transcript_path)) return payload.transcript_path;
  const base = homeDir() + '/.claude/projects';
  if (!existsSync(base)) return null;
  let best = null;
  for (const d of readdirSync(base)) {
    const dir = base + '/' + d;
    let ents = [];
    try { ents = readdirSync(dir); } catch { continue; }
    for (const f of ents) {
      if (!f.endsWith('.jsonl')) continue;
      if (payload.session_id && !f.includes(String(payload.session_id))) continue;
      const p = dir + '/' + f;
      let st; try { st = statSync(p); } catch { continue; }
      if (!best || st.mtimeMs > best.m) best = { p, m: st.mtimeMs };
    }
  }
  return best ? best.p : null;
}

const cardSlugs = text.split(/\r?\n/).filter((l) => l.startsWith('### ')).map((l) => ownSlugOf(l)).filter(Boolean);
const aliasLine = text.split(/\r?\n/).filter((l) => /^-\s*aliases\s*:/i.test(l)).join(' ').toLowerCase();
const TOKEN_MIN_LEN = 3;
const wantTokens = new Set();
for (const s of cardSlugs) for (const t of String(s).split(/[^a-z0-9]+/)) if (t.length >= TOKEN_MIN_LEN) wantTokens.add(t);
for (const t of aliasLine.split(/[^a-z0-9]+/)) if (t.length >= TOKEN_MIN_LEN) wantTokens.add(t);
const prNums = [...new Set(text.split(/\r?\n/).filter((l) => l.startsWith('### '))
  .flatMap((l) => [...l.matchAll(/#(\d{2,6})\b/g)].map((m) => m[1])))];

const KEYWORD_PROBE_RE = /\b(?:grep|rg|egrep|fgrep|wc|awk)\b|\|\s*head\b|\|\s*tail\b|\bhead\s+-|\btail\s+-/i;
const kindOf = (p) => (/-architecture\.md$/i.test(p) ? 'architecture'
  : /-plan\.md$/i.test(p) ? 'plan'
    : /[\\/]reviews[\\/]/i.test(p) ? 'verdict' : null);

const tp = transcriptPath();

const STATE_DIR = homeDir() + '/.claude/.state';
const STATE_FILE = process.env.AAL_WAVEDOC_STATE || (STATE_DIR + '/wave-doc-first-touch.json');
const STATE_TTL_MS = 7 * 24 * 3600 * 1000;

function loadState() {
  try { return JSON.parse(readFileSync(STATE_FILE, 'utf8')); } catch { return {}; }
}
function saveState(s) {
  try {
    mkdirSync(STATE_FILE.replace(/[\\/][^\\/]+$/, ''), { recursive: true });
    writeFileSync(STATE_FILE, JSON.stringify(s), 'utf8');
  } catch {  }
}
function readTailFrom(path, offset) {
  try {
    const size = statSync(path).size;
    if (!(offset < size)) return '';
    const fd = openSync(path, 'r');
    try {
      const buf = Buffer.allocUnsafe(size - offset);
      readSync(fd, buf, 0, buf.length, offset);
      return buf.toString('utf8');
    } finally { closeSync(fd); }
  } catch { return ''; }
}

const stateKey = `${payload.session_id || 'nosess'}::${cardSlugs.join(',') || '(noslug)'}`;
const state = loadState();
for (const k of Object.keys(state)) {
  if (!state[k] || (Date.now() - (state[k].atMs || 0)) > STATE_TTL_MS) delete state[k];
}
let sinceOffset = 0;
if (!state[stateKey]) {
  let cursor = 0;
  try { cursor = tp ? statSync(tp).size : 0; } catch { cursor = 0; }
  state[stateKey] = { atMs: Date.now(), at: new Date().toISOString(), cursor };
  saveState(state);
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason:
        'BLOCKED: the first completion token on any card is refused once, unconditionally. Reading done before this turn does not count.\n\n'
        + 'Do it now, then rewrite the line unchanged:\n'
        + '  Read docs/product-specs/R-<wave>-plan.md\n'
        + '  Read docs/product-specs/R-<wave>-architecture.md\n'
        + 'Both documents are required; a verdict file does not substitute for either.\n\n'
        + 'Reading in full means calling the Read tool; grep / sed -n / head / tail do not count.\n'
        + `card: ${cardSlugs.join(', ') || '(no slug)'}`,
    },
  }));
  process.exit(0);
}
sinceOffset = state[stateKey].cursor || 0;

let evidence = null;
let sawAnySpec = null;
const seenKinds = new Set();
let sawWholeRead = false;
const wholeReadKinds = new Set();
let wholeReadPath = null;
if (tp && wantTokens.size) {
  let t = '';
  if (sinceOffset > 0) t = readTailFrom(tp, sinceOffset);
  else { try { t = readTranscriptText(tp).text; } catch { t = ''; } }
  for (const ln of t.split(/\r?\n/)) {
    if (!/"name"\s*:\s*"(?:Read|Bash)"/.test(ln)) continue;
    const m = ln.match(SPEC_RE);
    if (!m) continue;
    if (!sawAnySpec) sawAnySpec = m[0];
    const path = m[0].toLowerCase();
    let hits = 0;
    for (const tok of wantTokens) if (path.includes(tok)) hits++;
    if (hits < 2) for (const pr of prNums) if (path.includes('pr' + pr)) { hits = 2; break; }
    if (hits < 2) continue;
    if (!evidence) evidence = m[0];
    const k = kindOf(path);
    if (k) seenKinds.add(k);
    const isReadTool = /"name"\s*:\s*"Read"/.test(ln);
    if (isReadTool) { sawWholeRead = true; if (k) wholeReadKinds.add(k); if (!wholeReadPath) wholeReadPath = m[0]; }
  }
}
const hasPlan = seenKinds.has('plan');
const hasArch = seenKinds.has('architecture');
const hasVerdict = seenKinds.has('verdict');
const twoDocs = hasPlan && hasArch;

const bothRead = wholeReadKinds.has('plan') && wholeReadKinds.has('architecture');
if (evidence && twoDocs && sawWholeRead && bothRead) allow();

process.stdout.write(JSON.stringify({
  hookSpecificOutput: {
    hookEventName: 'PreToolUse',
    permissionDecision: 'deny',
    permissionDecisionReason:
      'BLOCKED: this wave\u2019s plan AND architecture have to be Read before a completion token is written\n\n'
      + 'What this gate read:\n'
      + '  evidence matching THIS card : ' + (evidence ? evidence : 'none') + '\n'
      + '  plan was Read               : ' + (wholeReadKinds.has('plan') ? 'YES' : 'NO') + '\n'
      + '  architecture was Read       : ' + (wholeReadKinds.has('architecture') ? 'YES' : 'NO') + '\n'
      + (!evidence && sawAnySpec ? '  NOTE: what was read belongs to a DIFFERENT wave: ' + sawAnySpec + '\n' : '')
      + '\nRun these two, then rewrite:\n'
      + '  Read docs/product-specs/R-<wave>-plan.md\n'
      + '  Read docs/product-specs/R-<wave>-architecture.md\n\n'
      + 'Both are required; a verdict file substitutes for neither. Reading in full means the Read tool; grep / sed -n / head / tail / git show do not count.\n'
      + 'The token only takes effect on the card HEADER; writing it in the body does nothing.',
  },
}));
process.exit(0);

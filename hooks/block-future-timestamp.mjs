#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import { autoLogOnDeny } from './lib/log-denial.mjs';
autoLogOnDeny('block-future-timestamp');

function read(fd) { try { return readFileSync(fd, 'utf8'); } catch { return ''; } }
let payload = {};
try { payload = JSON.parse(read(0) || '{}'); } catch { process.exit(0); }

const tool = String(payload.tool_name || '');
if (!['Write', 'Edit', 'MultiEdit'].includes(tool)) process.exit(0);
const ti = payload.tool_input || {};

let text = '';
if (tool === 'Write') text = String(ti.content || '');
else if (tool === 'Edit') text = String(ti.new_string || '');
else if (tool === 'MultiEdit') text = (ti.edits || []).map((e) => String(e.new_string || '')).join('\n');
if (!text.trim()) process.exit(0);

const SKEW_MS = 120 * 1000;
const now = Date.now();

const FIELDS = [
  [/\bgate-observed-at\s*=\s*([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9x]{2}(?::[0-9x]{2})?Z)/gi, 'gate-observed-at'],
  [/\bgate-extended-at\s*=\s*([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9x]{2}(?::[0-9x]{2})?Z)/gi, 'gate-extended-at'],
  [/\bdod-failed-at\s*=\s*([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9x]{2}(?::[0-9x]{2})?Z)/gi, 'dod-failed-at'],
  [/\bdod-failed-cleared-at\s*=\s*([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9x]{2}(?::[0-9x]{2})?Z)/gi, 'dod-failed-cleared-at'],
  [/"ts"\s*:\s*"([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)"/g, 'reviews jsonl "ts"'],
  [/^[ \t]*-[ \t]*log:[ \t]*([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9x]{2}(?::[0-9x]{2})?Z)/gim, 'BACKLOG `- log:`'],
];

const toEarliest = (s) => s.replace(/x/gi, '0');

const bad = [];
for (const [re, label] of FIELDS) {
  for (const m of text.matchAll(re)) {
    const raw = m[1];
    const t = Date.parse(toEarliest(raw));
    if (Number.isNaN(t)) continue;
    if (t - now > SKEW_MS) bad.push({ label, raw, aheadMin: Math.round((t - now) / 60000) });
  }
}
const SHAPELESS_LOG = /^[ \t]*-[ \t]*log:[ \t]*([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2})Z/gm;
const shapeless = [...text.matchAll(SHAPELESS_LOG)].map((m) => `${m[1]}Z`);
if (shapeless.length) {
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason:
        `BLOCKED: a \`- log:\` stamp must carry SECONDS: ${shapeless.slice(0, 3).join(' · ')}\n\n`
        + `    - log: $(date -u +%Y-%m-%dT%H:%M:%SZ) · <who was dispatched>\n\n`
        + `A stamp without seconds matches NONE of the eight parsers that read it.`,
    },
  }));
  process.exit(0);
}

if (!bad.length) process.exit(0);

const nowIso = new Date(now).toISOString().replace(/\.\d+Z$/, 'Z');
const list = bad.slice(0, 5).map((b) => `${b.label}=${b.raw} (${b.aheadMin}min ahead)`).join(' · ');

const reason =
  `BLOCKED: NO-FABRICATED-TIMESTAMP GATE: this write ` +
  `contains an OBSERVATION timestamp in the FUTURE — ${list}. Real UTC is **${nowIso}**. ` +
  `A future observation stamp is not an observation: it was typed, not read from a clock. These ` +
  `fields are what every freshness computation runs on (P-timers, DoD-FAILED renewals, gate staleness), ` +
  `so a fabricated one makes those timers run on fiction. ` +
  `FIX: get the real time first — \`date -u +%Y-%m-%dT%H:%M:%SZ\` — and write THAT. ` +
  `(2026-07-28 incident: the lead wrote SEVEN gate-observed-at values ahead of the clock in one ` +
  `session; a plan-reviewer caught one and named the class. Redacted forms like \`13:5xZ\` are fine ` +
  `and resolve to their earliest minute — this gate only fires on genuinely future times. ` +
  `\`observe-until=\`/ETAs/cron are NOT checked: those are deliberately forward-looking.)`;

process.stdout.write(JSON.stringify({
  hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: reason },
}));
process.exit(0);

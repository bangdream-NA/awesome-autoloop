#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import { autoLogOnDeny } from './lib/log-denial.mjs';
import { projectPaths } from './lib/is-autoloop-lead.mjs';
autoLogOnDeny('block-dod-failed-without-execution');

function allow() { process.stdout.write('{}'); process.exit(0); }
function deny(reason) {
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: reason },
  }));
  process.exit(0);
}

let payload = {};
try { payload = JSON.parse(readFileSync(0, 'utf8') || '{}'); } catch { allow(); }

const tool = String(payload.tool_name || '');
if (!['Write', 'Edit', 'MultiEdit'].includes(tool)) allow();
const ti = payload.tool_input || {};
const file = String(ti.file_path || '').replace(/\\/g, '/');
if (!/\/\.claude\/BACKLOG[^/]*\.md$/i.test(file)) allow();

const ANCHOR_RE = /dod-failed-at=(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)/g;
const OBSERVED_RE = /(?:^|[\s·|])observed=\S+/i;
const EXPECTED_RE = /(?:^|[\s·|])expected=\S+/i;

const SHIP_LINE_RE = /^-\s*ship\s*:[^\n]*/im;
const SHIP_RAN_RE = /\bran=(\S+)/i;
const SHIP_OWNER_RE = /\bowner=(lead|user|auto)\b/i;

const WAVE_HINT_RE = /R-([a-z0-9-]+?)-(?:plan|architecture)\.md|R-([a-z0-9-]+?)-\{plan,architecture\}|feat\/r-([a-z0-9-]+)/i;
const SPEC_DIRS = [projectPaths()?.specs].filter(Boolean);

function shipSectionOf(block) {
  const m = String(block).match(WAVE_HINT_RE);
  const wave = m && (m[1] || m[2] || m[3]);
  if (!wave) return null;
  for (const d of SPEC_DIRS) {
    for (const suffix of ['-architecture.md', '-plan.md']) {
      try {
        const txt = readFileSync(`${d}/R-${wave}${suffix}`, 'utf8');
        const s = txt.match(/^#{1,3}\s*§S\s+Ship action[^\n]*\n([\s\S]{0,400})/im);
        if (s) return { wave, file: `R-${wave}${suffix}`, body: s[1].trim().split('\n')[0] };
      } catch {  }
    }
  }
  return { wave, file: null, body: null };
}

function shipUndischarged(block) {
  const line = (String(block).match(SHIP_LINE_RE) || [])[0];
  if (!line) return 'the card block has no `- ship:` line — nothing has said how this diff reaches production';
  const ran = (line.match(SHIP_RAN_RE) || [])[1];
  if (!ran) return '`- ship:` is present, but there is no `ran=` field';
  if (/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(ran)) return null;
  if (/^N-A:.+/i.test(ran)) return null;
  const owner = (line.match(SHIP_OWNER_RE) || [])[1] || 'unwritten';
  return `\`ran=${ran}\` (owner=${owner}) — the ship action has not run yet`;
}

function anchorsIn(text) { return new Set([...String(text).matchAll(ANCHOR_RE)].map((m) => m[1])); }

let before = '';
try { before = readFileSync(file, 'utf8'); } catch { before = ''; }

let after = '';
if (tool === 'Write') {
  after = String(ti.content || '');
} else if (tool === 'Edit') {
  const oldS = String(ti.old_string || '');
  after = oldS ? before.split(oldS).join(String(ti.new_string || '')) : before + String(ti.new_string || '');
} else {
  after = (ti.edits || []).reduce((acc, e) => {
    const o = String(e.old_string || '');
    return o ? acc.split(o).join(String(e.new_string || '')) : acc + String(e.new_string || '');
  }, before);
}
if (!after.trim()) allow();

const known = anchorsIn(before);
const fresh = [...anchorsIn(after)].filter((ts) => !known.has(ts));
if (!fresh.length) allow();

const offenders = [];
for (const block of after.split(/\n(?=### \[)/)) {
  if (!/^### \[/.test(block)) continue;
  const blockFresh = [...anchorsIn(block)].filter((ts) => fresh.includes(ts));
  if (!blockFresh.length) continue;
  const base = {
    card: (block.match(/R-[a-z0-9-]+/i) || ['(card)'])[0],
    ts: blockFresh[0],
    hasObserved: OBSERVED_RE.test(block),
    hasExpected: EXPECTED_RE.test(block),
  };
  if (!base.hasObserved || !base.hasExpected) { offenders.push(base); continue; }
  const why = shipUndischarged(block);
  if (why) offenders.push({ ...base, shipWhy: why, shipDoc: shipSectionOf(block) });
}
if (!offenders.length) allow();

const missing = (o) => [!o.hasObserved && 'observed=', !o.hasExpected && 'expected='].filter(Boolean).join(' + ');

const shipOffenders = offenders.filter((o) => o.shipWhy);
if (shipOffenders.length && shipOffenders.length === offenders.length) {
  const rows = shipOffenders.slice(0, 5).map((o) => {
    const d = o.shipDoc;
    const docLine = d && d.body
      ? `\n        -> ${d.file} §S Ship action, verbatim: "${d.body.slice(0, 90)}"`
      : (d && d.wave ? `\n        -> the spec for wave R-${d.wave} has **no §S Ship action** — which is itself the gap at this step` : '');
    return `    ${o.card} — new anchor ${o.ts}\n        ${o.shipWhy}${docLine}`;
  }).join('\n');
  deny(
    `BLOCKED: the measurement was taken BEFORE the ship action — that is not a failure, it is unfinished\n\n`
    + `${shipOffenders.length} card(s) carry \`observed=\`/\`expected=\` while ship has not handed over:\n${rows}\n\n`
    + `FIX, by WHO OWES THIS STEP:\n`
    + `  · the lead owns it (deploy / republish / workflow_dispatch) ⇒ go and run it now, then write\n`
    + `    \`- ship: <action> · owner=lead · ran=<ISO Z>\`\n`
    + `  · the user owns it (a root session, a console, credentials you cannot hold) ⇒ write on the card header\n`
    + `    \`blocked-by=user · asked-at=<ISO Z>\` (only after you really called AskUserQuestion this turn) — **not** \`DoD-FAILED\`\n`
    + `  · this wave genuinely has no ship action ⇒ \`- ship: … · ran=N-A:<reason>\`\n`
    + `If the ship action already has a runbook, read the runbook and execute it. Do not open a wave for it.`,
  );
}

deny(
  `BLOCKED: DoD-FAILED needs an EXECUTION, not a judgement\n\n` +
  `${offenders.length} card(s) introduce a new \`dod-failed-at=\` with no measurement recorded in the same card block:\n` +
  offenders.slice(0, 5).map((o) => `    ${o.card} — new anchor ${o.ts}, missing ${missing(o)}`).join('\n') + '\n\n' +
  `FIX. It never ran ⇒ go back and finish the DoD; there is no substitute token here.\n` +
  `It ran and it broke ⇒ write the pair in the same card block:\n` +
  `    dod-failed-at=<ISO Z> · observed=<what you actually saw> · expected=<what the runbook or the AC requires>\n` +
  `Then do these two things **immediately**:\n` +
  `  1. file a remedy card whose header carries \`dod-remedy-for=<source card slug>\`\n` +
  `  2. go back to the source card and append the remedy slug to \`dod-remedy-tracks=\` — **not optional**; without it that card cannot be dispatched\n` +
  `Self-check: \`grep -o 'dod-remedy-tracks=[^ ·]*' <board> | grep <remedy slug>\` (grep the FIELD, not the whole line)\n` +
  `Hanging \`blocked-by=merge-order:wave:<remedy card>\` on the source card needs BOTH: this card cannot land before the awaited thing lands, ` +
  `AND the remedy card already has someone on it (\`stage=\` is past \`new\`).\n` +
  `Unaffected: re-anchoring on the hour (the stamp already in the file) · \`dod-failed-cleared-at=\`.`);

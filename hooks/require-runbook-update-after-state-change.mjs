#!/usr/bin/env node

import { readFileSync } from 'node:fs';
import { serverStateChange, RUNBOOK_PREFIX } from './lib/server-op-state-change.mjs';
import { lastAssistantText, readTranscriptText } from './lib/transcript-last-assistant.mjs';
import { autoLogOnDeny } from './lib/log-denial.mjs';
autoLogOnDeny('require-runbook-update-after-state-change');

const allow = () => { process.stdout.write('{}'); process.exit(0); };

let input;
try { input = JSON.parse(readFileSync(0, 'utf8')); } catch { allow(); }

const tp = input && input.transcript_path;
if (!tp || typeof tp !== 'string') allow();

let raw = '';
try { raw = readTranscriptText(tp).text; } catch { allow(); }
if (!raw) allow();

const lines = raw.split(/\r?\n/).filter(Boolean);

const userText = (m) => {
  if (typeof m.content === 'string') return m.content;
  if (Array.isArray(m.content)) {
    return m.content.filter((p) => p && p.type === 'text').map((p) => p.text || '').join(' ');
  }
  return '';
};

const IS_MARKER = /^\s*\[Request interrupted by user\]\s*$/;
let turnStart = 0;
for (let i = lines.length - 1; i >= 0; i--) {
  let j; try { j = JSON.parse(lines[i]); } catch { continue; }
  const m = j && j.message;
  if (!m || m.role !== 'user') continue;
  const t = userText(m).trim();
  if (!t || IS_MARKER.test(t)) continue;
  turnStart = i; break;
}

const hits = [];
let runbookWrite = false;

for (let i = turnStart; i < lines.length; i++) {
  let j; try { j = JSON.parse(lines[i]); } catch { continue; }
  const parts = (j && j.message && Array.isArray(j.message.content)) ? j.message.content : [];
  for (const p of parts) {
    if (!p || p.type !== 'tool_use') continue;
    const inp = p.input || {};
    if (p.name === 'Bash' && typeof inp.command === 'string') {
      const r = serverStateChange(inp.command);
      if (r.changed) hits.push({ cmd: inp.command.slice(0, 160), what: r.what });
    }
    if ((p.name === 'Write' || p.name === 'Edit' || p.name === 'NotebookEdit')
        && typeof inp.file_path === 'string'
        && inp.file_path.replace(/\\/g, '/').includes(RUNBOOK_PREFIX)) {
      runbookWrite = true;
    }
  }
}

if (!hits.length) allow();
if (runbookWrite) allow();

const said = lastAssistantText(input);
if (/RUNBOOK-DEBT-NONE:\s*\S/.test(said)) allow();

const bt = String.fromCharCode(96);
const q = (s) => bt + s + bt;
const list = hits.slice(0, 3)
  .map((h) => `  · ${h.what.join(' / ')}\n      ${q(h.cmd)}`).join('\n');

process.stdout.write(JSON.stringify({
  decision: 'block',
  reason:
    `BLOCKED: this turn changed PERSISTENT STATE on the box, and ${q('docs/runbooks/')} received zero writes\n\n` +
    `${hits.length} match(es):\n${list}\n\n` +
    `FIX, one of two:\n` +
    `  1. update the runbook — ask "which paragraphs describe, in the present or future tense, the thing I just changed?" Every one of those is now FALSE.\n` +
    `     The update carries an evidence pointer (the date, the ledger batch, the command and its output). "Done" on its own is not an update.\n` +
    `  2. there genuinely is no documentation debt ⇒ write one line in your reply: ${q('RUNBOOK-DEBT-NONE: <reason>')}\n` +
    `Writing it into the op-log does NOT count — that is precisely why this gate exists.`,
}));
process.exit(0);

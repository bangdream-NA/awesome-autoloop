#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import { isDodFailedDialectDrift } from './lib/backlog-gate.mjs';
import { autoLogOnDeny } from './lib/log-denial.mjs';
autoLogOnDeny('backlog-dod-anchor-required');

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

let after = '';
try {
  if (tool === 'Write') {
    after = String(ti.content || '');
  } else {
    const before = readFileSync(file, 'utf8');
    if (tool === 'Edit') {
      const oldS = String(ti.old_string || '');
      after = oldS ? before.split(oldS).join(String(ti.new_string || '')) : before + String(ti.new_string || '');
    } else {
      after = (ti.edits || []).reduce((acc, e) => {
        const o = String(e.old_string || '');
        return o ? acc.split(o).join(String(e.new_string || '')) : acc;
      }, before);
    }
  }
} catch {
  after = tool === 'Write' ? String(ti.content || '')
    : tool === 'Edit' ? String(ti.new_string || '')
      : (ti.edits || []).map((e) => String(e.new_string || '')).join('\n');
}
if (!after.trim()) allow();

const offenders = [];
for (const block of after.split(/\n(?=### \[)/)) {
  if (!/^### \[/.test(block)) continue;
  if (!isDodFailedDialectDrift(block)) continue;
  offenders.push((block.match(/R-[a-z0-9-]+/i) || ['(card)'])[0]);
}
if (!offenders.length) allow();

const nowIso = new Date().toISOString().replace(/\.\d+Z$/, 'Z');
deny(
  `BLOCKED: DoD-FAILED with no machine anchor — ${offenders.length} card block(s) assert a LIVE DoD failure without ` +
  `\`dod-failed-at=<ISO Z>\`:${offenders.slice(0, 5).join(' · ')}\n\n` +
  `FIX: add one line to that card block, using the value you just read:\n` +
  `    dod-failed-at=${nowIso}\n` +
  `Read the timestamp from \`date -u +%Y-%m-%dT%H:%M:%SZ\`; never write it from memory — an invented future value is refused by ` +
  `\`block-future-timestamp.mjs\`. Do not round it up.\n` +
  `Recording that the failure is RESOLVED ⇒ write \`dod-failed-cleared-at=<ISO Z>\`; the prose word "released" does not count.`);

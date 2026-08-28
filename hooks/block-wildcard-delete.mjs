#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import { autoLogOnDeny } from './lib/log-denial.mjs';
autoLogOnDeny('block-wildcard-delete');

let raw = '';
try { raw = readFileSync(0, 'utf8'); } catch { process.exit(0); }
let cmd = '';
try { cmd = (JSON.parse(raw).tool_input || {}).command || ''; } catch {
  const m = raw.match(/"command"\s*:\s*"((?:[^"\\]|\\.)*)"/);
  if (m) { try { cmd = JSON.parse('"' + m[1] + '"'); } catch { cmd = m[1]; } }
}
if (!cmd) process.exit(0);

if (/#\s*RM-GLOB-OK:/i.test(cmd)) process.exit(0);

const DISPOSABLE = /(^|[\s'"=(])(?:[A-Za-z]:)?[\\/]?(?:[^\s'"]*[\\/])?(?:scratchpad|AppData[\\/]Local[\\/]Temp|[\\/]tmp[\\/]|node_modules|__pycache__|\.pytest_cache|\.next[\\/]cache|dist[\\/])/i;

const SEGS = cmd.split(/;|&&|\|\||\||\n/);
const CMDPOS = String.raw`(?:^|-c\s+["'])\s*(?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)*(?:sudo\s+)?`;
const RM = new RegExp(CMDPOS + String.raw`(rm|del|erase)\s`, 'i');
const PS_RM = new RegExp(CMDPOS + String.raw`(?:powershell\S*\s+[^"']*["']\s*)?Remove-Item[^\n;|&]*`, 'i');
const HAS_GLOB = (s) => /[*?]/.test(s) || /\[[^\]]+\]/.test(s);

const offend = [];
for (const seg of SEGS) {
  const s = seg.trim(); if (!s) continue;
  const m = s.match(RM);
  if (m) {
    const args = s.replace(/^.*?\b(rm|del|erase)\b/, '').split(/\s+/).filter((a) => a && !a.startsWith('-'));
    for (const a of args) {
      const bare = a.replace(/^['"]|['"]$/g, '');
      if (HAS_GLOB(bare) && !DISPOSABLE.test(bare)) offend.push({ verb: 'rm', arg: bare });
    }
  }
  const p = s.match(PS_RM);
  if (p) {
    for (const a of (p[0].match(/(['"])([^'"]*[*?][^'"]*)\1|(\S*[*?]\S*)/g) || [])) {
      const bare = a.replace(/^['"]|['"]$/g, '');
      if (!/^-/.test(bare) && !DISPOSABLE.test(bare)) offend.push({ verb: 'Remove-Item', arg: bare });
    }
  }
}
if (!offend.length) process.exit(0);

const list = offend.slice(0, 4).map((o) => `      ${o.verb}  ${o.arg}`).join('\n');
const reason = [
  'BLOCKED: a delete with a wildcard',
  '',
  'matched:',
  list,
  '',
  'FIX, in priority order:',
  '  1. delete by EXACT filename: run `ls -1 <glob>` as its OWN command first, read that output,',
  '     then write the confirmed names into `rm` one by one. When cleaning up after your own failed operation, this is the only correct route.',
  '  2. the target really is one-off scratch (a scratchpad / Temp / node_modules / dist) ⇒ write the path out in full and it is allowed automatically.',
  '  3. the wildcard is genuinely necessary AND you have checked every item it matches ⇒ append `# RM-GLOB-OK: <reason>` to the command.',
].join('\n');

process.stdout.write(JSON.stringify({
  hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: reason },
}));

#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import { logDenial } from './lib/log-denial.mjs';

let j = {};
try { j = JSON.parse(readFileSync(0, 'utf8') || '{}'); } catch { process.exit(0); }
if (String(j.tool_name || '') !== 'Bash') process.exit(0);
const cmd = String((j.tool_input && j.tool_input.command) || '');
if (!cmd) process.exit(0);
if (/#\s*INLINE-OK:/i.test(cmd)) process.exit(0);

const RE = /\b(?:node|python3?|python)\b[^\n|;&]*?\s(?:-e|-c|--eval)\s+("(?:[^"\\]|\\[\s\S])*"|'[^']*')/g;

const offences = [];
for (const m of cmd.matchAll(RE)) {
  const q = m[1][0];
  const body = m[1].slice(1, -1);
  if (q === '"') {
    if (/[`$\\]/.test(body)) offences.push('a "…" payload containing ` $ or \\');
  } else {
    if (/\\/.test(body)) offences.push("a '…' payload containing \\ (MSYS rewrites it)");
    const after = cmd.slice((m.index ?? 0) + m[0].length);
    if (/^\\''/.test(after) || /'\\''/.test(m[0])) offences.push("the '\\'' splicing idiom (fragile)");
  }
}
if (!offences.length) process.exit(0);

const reason = `BLOCKED: INLINE-HOSTILE-CHAR. The inline script contains characters the shell or MSYS will rewrite (${[...new Set(offences)].join(' · ')}). FIX: Write it to a file under your scratch dir, then run \`node <absolute path>\`. Exemption: append \`# INLINE-OK: <reason>\`.`;
logDenial('block-inline-script-with-hostile-text', 'inline-hostile-text', reason);
process.stdout.write(JSON.stringify({
  hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: reason },
}));
process.exit(0);

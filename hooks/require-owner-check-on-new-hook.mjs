#!/usr/bin/env node
import { readFileSync, existsSync } from 'node:fs';
import { autoLogOnDeny } from './lib/log-denial.mjs';
import { hookFilesWrittenBy } from './lib/script-mediated-hook-writes.mjs';
autoLogOnDeny('require-owner-check-on-new-hook');

const allow = () => { process.stdout.write('{}'); process.exit(0); };

let input = {};
try { input = JSON.parse(readFileSync(0, 'utf8') || '{}'); } catch { allow(); }

const tool = String(input.tool_name || '');
if (!['Write', 'Bash'].includes(tool)) allow();

const ti = input.tool_input || {};
let fp = String(ti.file_path || ti.filePath || '').replace(/\\/g, '/');
let bodyForCheck = null;
if (tool === 'Bash') {
  const targets = hookFilesWrittenBy(input).filter((p) => !existsSync(p));
  if (!targets.length) allow();
  fp = targets[0];
  bodyForCheck = '';
  for (const m of String(ti.command || '').matchAll(/\b(?:node|python3?|bun|deno(?:\s+run)?)\s+(?:--?\S+\s+)*["']?([^\s"'|;&]+\.(?:mjs|cjs|js|ts|py))["']?/g)) {
    try { bodyForCheck += '\n' + readFileSync(m[1].replace(/\\/g, '/'), 'utf8'); } catch {  }
  }
  bodyForCheck += '\n' + String(ti.command || '');
}

if (!/\.claude\/hooks\/(lib\/)?[^/]+\.(mjs|sh|js)$/.test(fp)) allow();
if (/\.claude\/hooks\/__tests__\//.test(fp)) allow();
if (tool === 'Write' && existsSync(ti.file_path)) allow();

const content = bodyForCheck !== null ? bodyForCheck : String(ti.content || '');
if (/OWNER-CHECK:/.test(content)) allow();

process.stdout.write(JSON.stringify({
  hookSpecificOutput: {
    hookEventName: 'PreToolUse',
    permissionDecision: 'deny',
    permissionDecisionReason:
      `BLOCKED: before creating a new hook, prove this concept has no owner\n` +
      `target: ${fp}\n\n` +
      `FIX: grep for the owner first:\n` +
      `  ls <hooks dir> | grep -iE '<keywords for this concept>'\n` +
      `  grep -rl '<the predicate you intend to judge>' <hooks dir>/*.mjs\n` +
      `Found one ⇒ add the rule to THAT file rather than creating a new one (**the default outcome**).\n` +
      `Genuinely none ⇒ write one comment line in the new file:\n` +
      `    // OWNER-CHECK: <the closest existing hook> — <why it cannot hold this rule>\n` +
      `    // OWNER-CHECK: none — <the grep you ran, and that it returned 0>`,
  },
}));
process.exit(0);

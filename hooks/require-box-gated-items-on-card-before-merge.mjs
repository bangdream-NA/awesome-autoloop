#!/usr/bin/env node
import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { projectPaths } from './lib/is-autoloop-lead.mjs';

const allow = () => { process.stdout.write('{}'); process.exit(0); };
const deny = (reason) => {
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: reason },
  }));
  process.exit(0);
};

let payload;
try { payload = JSON.parse(readFileSync(0, 'utf8') || '{}'); } catch { allow(); }
const tool = String(payload.tool_name || '');
const isWrite = /^(Write|Edit|MultiEdit)$/.test(tool);
const REVIEWS = projectPaths()?.reviews || '';
let pr = '';
let file = '';
let verdict = '';

if (!isWrite) allow();
{
  const tin = payload.tool_input || {};
  const target = String(tin.file_path || '').replace(/\\/g, '/');
  const vm = target.match(/\.claude\/reviews\/pr(\d+)-r(\d+)\.md$/i);
  if (!vm) allow();
  pr = vm[1];
  file = `pr${vm[1]}-r${vm[2]}.md`;
  verdict = [tin.content, tin.new_string,
    ...(Array.isArray(tin.edits) ? tin.edits.map((e) => e && e.new_string) : [])]
    .filter(Boolean).join('\n');
  if (!verdict) allow();
}

const SECTIONS = [
  /^#{1,4}\s*Boundaries I did NOT cross[^\n]*$/im,
  /^#{1,4}\s*Edge cases still to test[^\n]*$/im,
  /^#{1,4}\s*(?:Box-gated|box-only)[^\n]*$/im,
];
const lines = verdict.split(/\r?\n/);
const found = [];
for (const re of SECTIONS) {
  const i = lines.findIndex((l) => re.test(l));
  if (i < 0) continue;
  let end = lines.length;
  for (let k = i + 1; k < lines.length; k += 1) {
    if (/^#{1,4}\s/.test(lines[k]) || /^---\s*$/.test(lines[k])) { end = k; break; }
  }
  const body = lines.slice(i + 1, end).join('\n').trim();
  if (!body || /^(?:none|N-?A)\b/i.test(body)) continue;
  found.push({ heading: lines[i].replace(/^#+\s*/, '').slice(0, 70), n: body.split('\n').filter((x) => x.trim()).length });
}
if (!found.length) allow();

deny(
  `BLOCKED: \`${file}\` contains a section marked NOT YET VERIFIED, so this review round is unfinished and cannot be handed over.\n`
  + found.map((f) => `    · "${f.heading}" — ${f.n} line(s)`).join('\n') + '\n'
  + `Do it now; for each item pick one of two:\n`
  + `  1. verify it yourself, and write the command and the reading into the verdict;\n`
  + `  2. it genuinely can only be verified AFTER shipping ⇒ write it as a **DoD ITEM**: name the action to take and the reading that decides it.\n`
  + `Neither of those is a "still to test" list — nothing will ever bring anyone back to read one of those.`,
);

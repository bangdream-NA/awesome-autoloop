#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import { stageOf, statusOf, slugOf } from './lib/backlog-gate.mjs';
import { autoLogOnDeny } from './lib/log-denial.mjs';
autoLogOnDeny('backlog-ownership-token-required');

const allow = () => { process.stdout.write('{}'); process.exit(0); };
function deny(reason) {
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: reason },
  }));
  process.exit(0);
}

let payload;
try { payload = JSON.parse(readFileSync(0, 'utf8') || '{}'); } catch { allow(); }

const tool = String(payload.tool_name || '');
if (!['Write', 'Edit', 'MultiEdit'].includes(tool)) allow();

const ti = payload.tool_input || {};
const file = String(ti.file_path || '').replace(/\\/g, '/');
if (!/\/\.claude\/BACKLOG[^/]*\.md$/i.test(file)) allow();

let introduced = '';
if (tool === 'Write') introduced = String(ti.content || '');
else if (tool === 'Edit') introduced = String(ti.new_string || '');
else if (tool === 'MultiEdit') introduced = (ti.edits || []).map((e) => String(e.new_string || '')).join('\n');
if (!introduced.trim()) allow();

const OWNERSHIP_RE = /(?:PR|MERGED)\s*#\d+\b/;

const IN_SCOPE_STAGES = new Set(['pr', 'review']);

const offenders = [];
for (const line of introduced.split(/\r?\n/)) {
  if (!/^### \[/.test(line)) continue;
  const inScope = IN_SCOPE_STAGES.has(stageOf(line)) || statusOf(line) === 'REVIEW';
  if (!inScope) continue;
  if (OWNERSHIP_RE.test(line)) continue;
  const name = slugOf(line) || (line.match(/R-[a-z0-9-]+/i) || ['(card)'])[0];
  const why = /\*\*\s*#\d+/.test(line)
    ? 'the number IS on the header but markdown bold sits between `PR ` and `#` — that breaks every consumer\'s regex'
    : (/#\d+/.test(line) ? 'a `#N` appears but not in an ownership spelling' : 'no `PR #N` anywhere on the header line');
  offenders.push(`  · ${name} — ${why}`);
}

if (!offenders.length) allow();

deny(
  `BLOCKED: the card header is missing its OWNERSHIP TOKEN — the card claims to have a PR (\`stage=pr\`/\`review\` or \`[REVIEW]\`), and its header does not carry one:\n` +
  offenders.join('\n') + '\n\n' +
  `FIX: add an UNDECORATED \`PR #<N>\` to the \`### \` line:\n` +
  `  \`### [REVIEW] R-foo · stage=review · PR #1177 · P1 · **title**\`\n` +
  `After it merges, change it to \`MERGED #<N>\`.\n` +
  `Four things that do NOT count: \`PR **#1177**\` (bold in the middle) · only inside \`- log:\` · lowercase \`pr#<N>\` (that is the DEPENDENCY token) · leaving it blank for the CI watcher to infer.\n` +
  `There genuinely is no PR yet ⇒ go back to \`stage=dev\` / \`[IN-DEV]\`; do not leave the token blank.`,
);

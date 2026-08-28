#!/usr/bin/env node
//      D-2 — `deploy/bin/**` is not covered by shellcheck => one card
import { readFileSync } from 'node:fs';

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
if (!/^(Write|Edit|MultiEdit)$/.test(tool)) allow();

const ti = payload.tool_input || {};
const file = String(ti.file_path || '').replace(/\\/g, '/');
const isPlan = /\/docs\/product-specs\/R-[^/]*-plan\.md$/i.test(file);
const isArch = /\/docs\/product-specs\/R-[^/]*-architecture\.md$/i.test(file);
if (!isPlan && !isArch) allow();

let before = '';
try { before = readFileSync(file, 'utf8'); } catch { before = ''; }

let after = '';
if (tool === 'Write') {
  after = String(ti.content || '');
} else if (tool === 'Edit') {
  const o = String(ti.old_string || '');
  after = o ? before.split(o).join(String(ti.new_string || '')) : before + String(ti.new_string || '');
} else {
  after = (ti.edits || []).reduce((acc, e) => {
    const o = String(e.old_string || '');
    return o ? acc.split(o).join(String(e.new_string || '')) : acc + String(e.new_string || '');
  }, before);
}
if (!after.trim()) allow();

const SECOND_PR_RE = new RegExp(
  '\\bPR\\s*[2-9]\\b|\\bPR\\s*1\\s*\\/\\s*2\\b|\\btwo\\s+PRs\\b|\\bsecond\\s+PR\\b|\\bsplit into\\s+\\d+\\s+PRs\\b'
  + '|\\b[2-9]\\d*\\s+PRs\\b'
  + '|\\bone\\s+PR\\s+per\\s+batch\\b'
  + '|\\bBatch\\s*[2-9]\\b'
  + '|\\bin batches\\b|\\beach batch\\b|\\b\\d+\\s+batches\\b',
  'i');
const offending = after.split(/\r?\n/)
  .map((l, i) => [i + 1, l])
  .filter(([, l]) => SECOND_PR_RE.test(l) && !/#\s*\d/.test(l));
if (offending.length) {
  const [ln, text] = offending[0];
  deny(
    `BLOCKED: one wave = one card = one PR\n\n`
    + `  ${file.split('/').slice(-1)[0]}:${ln}\n`
    + `  "${text.trim().slice(0, 120)}"\n`
    + `  ${offending.length - 1} more of the same.\n\n`
    + `FIX, one of three:\n`
    + `  1. fold it back into this wave's File Map and deliver it in ONE PR — the default outcome\n`
    + `  2. it refers to ANOTHER wave's PR ⇒ write the number \`#<N>\` on the same line; this gate only catches the unnumbered ones\n`
    + `  3. you judge that this wave structurally cannot hold it ⇒ **do not split it yourself**; write it as an Open Question for the lead to rule on\n\n`
    + `NOTE: "that channel cannot return anything new until it is installed" is not a reason to split a PR — that is about whether it is USEFUL at runtime, not about whether it can MERGE.`,
  );
}

if (!isPlan) allow();

const lines = after.split(/\r?\n/);
const startIdx = lines.findIndex((l) => /^#{1,4}\s*(?:DoD|Definition of Done)\b/i.test(l));
if (startIdx < 0) allow();
let endIdx = lines.length;
for (let i = startIdx + 1; i < lines.length; i += 1) {
  if (/^#{1,4}\s/.test(lines[i]) || /^---\s*$/.test(lines[i])) { endIdx = i; break; }
}
const body = lines.slice(startIdx + 1, endIdx).join('\n');
if (!body.trim()) allow();

if (/LIVE-N-?A\s*:\s*\S/i.test(body)) allow();

const LIVE_ITEM = new RegExp(
  '(?:walk|walked|first-hand|really ran|re-?measure|re-?verify|acceptance)[^\\n]{0,20}(?:live|production|the box|prod)'
  + '|(?:live|production|the box|on the box)[^\\n]{0,20}(?:walk|walked|first-hand|really ran|re-?measure|verify|verified|observe|re-?run)'
  + '|(?:curl|Playwright|playwright|screenshot|systemctl|journalctl|workflow_dispatch|gh run)'
  + '|(?:post-?deploy|post-?merge)[^\\n]{0,24}(?:verify|walk|check)',
  'm');
if (LIVE_ITEM.test(body)) allow();

deny(
  `BLOCKED: the plan's DoD section has no item that says IT HAS TO BE ALIVE IN PRODUCTION\n\n`
  + `  file: ${file.split('/').slice(-1)[0]}\n`
  + `  what the DoD section currently holds (first 200 chars): "${body.trim().slice(0, 200).replace(/\n/g, ' / ')}"\n\n`
  + `FIX. Add one item that goes and looks at production; any shape will do:\n`
  + `  · \`D-N — after deploying, run <command> on the box and assert <observation>\`\n`
  + `  · \`D-N — walk it live: <entry> -> <each layer> -> <final result>, with a mobile screenshot\`\n`
  + `  · \`D-N — post-merge, trigger <workflow> and read its .steps[] rather than the job conclusion\`\n`
  + `Structurally produces nothing observable in production (a pure internal refactor, comments only) ⇒ write \`LIVE-N-A: <reason>\` in the DoD section.`,
);

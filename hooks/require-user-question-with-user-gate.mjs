#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import { autoLogOnDeny } from './lib/log-denial.mjs';
autoLogOnDeny('require-user-question-with-user-gate');

import { readTranscriptTail, userPresenceFrom, RECENT_MS } from './lib/user-presence.mjs';

const allow = () => { process.stdout.write('{}'); process.exit(0); };
const deny = (reason) => {
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: reason },
  }));
  process.exit(0);
};
function read(fd) { try { return readFileSync(fd, 'utf8'); } catch { return ''; } }

let stdin = {};
try { stdin = JSON.parse(read(0) || '{}'); } catch { allow(); }

const tool = String(stdin.tool_name || '');
if (!['Write', 'Edit', 'MultiEdit'].includes(tool)) allow();

const ti = stdin.tool_input || {};
const fp = String(ti.file_path || ti.filePath || '').replace(/\\/g, '/');
if (!/\.claude\/BACKLOG[^/]*\.md$/.test(fp)) allow();

let introduced = '';
if (tool === 'Write') introduced = String(ti.content || '');
else if (tool === 'Edit') introduced = String(ti.new_string || '');
else if (tool === 'MultiEdit') introduced = (ti.edits || []).map((e) => String(e.new_string || '')).join('\n');
if (!introduced.trim()) allow();

let result = introduced;
if (tool !== 'Write') {
  try { result = readFileSync(ti.file_path, 'utf8'); } catch { result = introduced; }
  result = `${result}\n${introduced}`;
}

const GATE_RE = /blocked-by=user\b|\[USER-GATED\]/;
const QUESTION_RE = /^-\s*user-question\s*:/m;
const TWO_OPTIONS_RE = /\|.*\||\/.*\/|(?:^|\s)1[.)].*(?:^|\s)2[.)]|\(a\).*\(b\)/is;

const introducedGateHeaders = introduced.split(/\r?\n/).filter((l) => /^###\s+\[/.test(l) && GATE_RE.test(l));

const tail = readTranscriptTail(String(stdin.transcript_path || ''));
const presence = userPresenceFrom(tail);
const present = !!presence?.present;
const sinceMs = Number(presence?.sinceMs ?? Number.POSITIVE_INFINITY);

const removingGate = (() => {
  const before = String(ti.old_string ?? '');
  const after = String(ti.new_string ?? '');
  if (!before) return false;
  const lost = (re) => re.test(before) && !re.test(after);
  return lost(/blocked-by=user\b/) || lost(/\[USER-GATED\]/) || lost(/^-\s*user-question\s*:/m);
})();

if (present && !removingGate) {
  const live = (() => {
    try { return readFileSync('Z:/my-project/.claude/BACKLOG.md', 'utf8'); } catch { return ''; }
  })();
  const stale = live.split(/\r?\n/).filter((l) => /^###\s+\[/.test(l) && GATE_RE.test(l));
  if (stale.length) {
    deny(
      'BLOCKED: they have already spoken, and a user gate is still on the board — next turn the open question will read as "still unanswered"\n\n'
      + stale.slice(0, 3).map((h) => `  • ${h.slice(0, 110)}`).join('\n')
      + '\n\nFIX, all three in THIS turn, before anything else:\n'
      + '  1. delete the `- user-question:` line, and **replace it with what they answered** — quote them verbatim, do not paraphrase\n'
      + '     (what they give is often a fourth option that was not on the menu, and a paraphrase folds it back into the ones you listed)\n'
      + '  2. remove `blocked-by=user` and `asked-at=` from the card header, and change the badge from `[USER-GATED]` back to its real state\n'
      + '  3. add `- log: <ISO Z> · answered <20 chars or fewer>`, and record a line in the op-log\n\n'
      + 'NOTE: if THIS one really is unanswered ⇒ call `AskUserQuestion` in this same turn. Do not leave the gate standing and go do something else.',
    );
  }
}

if (!introducedGateHeaders.length) allow();

if (present) {
  deny(
    `BLOCKED: they spoke ${Math.round(sinceMs / 1000)} seconds ago, so \`blocked-by=user\` / \`[USER-GATED]\` is not legal\n\n`
    + `    ${introducedGateHeaders[0].slice(0, 90)}\n\n`
    + `Call \`AskUserQuestion\` now, get the answer, and then change the board. This field only becomes legal after ${Math.round(RECENT_MS / 60000)} minutes of silence.`,
  );
}

if (present && Number.isFinite(sinceMs)) {
  const spokeAtMs = Date.now() - sinceMs;
  const stale = [];
  for (const line of result.split(/\r?\n/)) {
    if (!/^###\s+\[/.test(line) || !GATE_RE.test(line)) continue;
    const m = line.match(/asked-at=(\d{4}-\d{2}-\d{2}T[\d:]+Z)/);
    if (!m) continue;
    const askedMs = Date.parse(m[1]);
    if (!Number.isFinite(askedMs) || askedMs >= spokeAtMs) continue;
    stale.push({ head: line.slice(0, 100), asked: m[1] });
  }
  if (stale.length) {
    deny(
      'BLOCKED: they have already spoken, and the "I asked" mark is still on the card — next turn it will read as "still unanswered"\n\n'
      + stale.slice(0, 3).map((s) => `  • asked-at=${s.asked} (earlier than the last thing they said)\n    ${s.head}`).join('\n')
      + '\n\nFIX, all three in THIS turn, before anything else:\n'
      + '  1. delete the `- user-question:` line, and **replace it with what they answered** — quote them verbatim, do not paraphrase\n'
      + '     (what they give is often a fourth option that was not on the menu, and a paraphrase folds it back into the ones you listed)\n'
      + '  2. remove `blocked-by=user` and `asked-at=` from the card header, and change the badge from `[USER-GATED]` back to its real state\n'
      + '  3. add `- log: <ISO Z> · answered <20 chars or fewer>`, and record a line in the op-log\n\n'
      + 'NOTE: if they really have not answered THIS one, then that `asked-at=` is stale — ask again and update the stamp.',
    );
  }
}

const blocks = result.split(/^### /m);
const offenders = [];
for (const h of introducedGateHeaders) {
  const key = h.replace(/^###\s+/, '').slice(0, 60);
  const blk = blocks.find((b) => b.startsWith(key.slice(0, 40)));
  const body = blk || '';
  if (!QUESTION_RE.test(body)) { offenders.push({ h, why: 'no `- user-question:` field' }); continue; }
  const qline = (body.match(/^-\s*user-question\s*:.*$/m) || [''])[0];
  if (!TWO_OPTIONS_RE.test(qline)) offenders.push({ h, why: 'no two options visible inside `- user-question:`' });
}
if (!offenders.length) allow();

const reason =
  'BLOCKED: a user gate is set without writing down the question it is waiting on\n\n'
  + offenders.slice(0, 3).map((o) => `  • ${o.why}\n    ${o.h.slice(0, 100)}`).join('\n') + '\n\n'
  + 'FIX. Add this line to the same card as the gate, and give each option its CONSEQUENCE, not just a name:\n'
  + '    - user-question: <the question in one sentence> | option A: <consequence> | option B: <consequence> | my recommendation: <A or B, plus one line of reasoning>';

process.stdout.write(JSON.stringify({
  hookSpecificOutput: {
    hookEventName: 'PreToolUse',
    permissionDecision: 'deny',
    permissionDecisionReason: reason,
  },
}));
process.exit(0);

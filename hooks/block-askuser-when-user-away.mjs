#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import { userPresenceFrom, readTranscriptTail, RECENT_MS } from './lib/user-presence.mjs';
import { autoLogOnDeny } from './lib/log-denial.mjs';
autoLogOnDeny('block-askuser-when-user-away');

const allow = () => { process.stdout.write('{}'); process.exit(0); };
function read(fd) { try { return readFileSync(fd, 'utf8'); } catch { return ''; } }

let stdin = {};
try { stdin = JSON.parse(read(0) || '{}'); } catch { allow(); }

if (String(stdin.tool_name || '') !== 'AskUserQuestion') allow();

const tp = String(stdin.transcript_path || '');
if (!tp) allow();

const lines = readTranscriptTail(tp);
if (!lines) allow();
if (!lines.length) allow();

const { present, ageMs } = userPresenceFrom(lines);
if (present) allow();

const mins = ageMs === null ? null : Math.round(ageMs / 60000);
const ageTxt = mins === null
  ? 'the transcript holds no timestamped real user message at all'
  : `they last spoke **${mins} minutes ago** (the window is ${Math.round(RECENT_MS / 60000)} minutes)`;

const reason =
  `BLOCKED: the user is not here right now, so this question would wait indefinitely\n\n`
  + `${ageTxt}.\n\n`
  + `FIX, four steps, then go and work on something else:\n`
  + `  1. add \`blocked-by=user\` and \`asked-at=<the value you read back from date -u +%Y-%m-%dT%H:%M:%SZ>\` to the card header\n`
  + `  2. on the same card write \`- user-question: <the question in one sentence> | option A: <consequence> | option B: <consequence> | my recommendation: <A or B, plus the reasoning>\`\n`
  + `     — the question is still in your head right now, so write it down now. Without it, \`require-user-question-with-user-gate\` refuses the write\n`
  + `  3. \`- log: <the same ISO stamp> · lead · user gate set\`\n`
  + `  4. move to a card that does not depend on this decision\n\n`
  + `NOTE: do not reword and retry — this gate judges WHETHER THEY ARE HERE, not how well the question is written.`;

process.stdout.write(JSON.stringify({
  hookSpecificOutput: {
    hookEventName: 'PreToolUse',
    permissionDecision: 'deny',
    permissionDecisionReason: reason,
  },
}));
process.exit(0);

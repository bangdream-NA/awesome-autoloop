#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import { autoLogOnDeny } from './lib/log-denial.mjs';
import { MEASURED_RE } from './lib/measured-markers.mjs';
import { readLeadMarker, sidOf } from './lib/is-autoloop-lead.mjs';
autoLogOnDeny('require-measured-ref-claim');

const allow = () => { process.stdout.write('{}'); process.exit(0); };

let input = {};
try { input = JSON.parse(readFileSync(0, 'utf8') || '{}'); } catch { allow(); }

const leadMarks = readLeadMarker();
const callerSid = sidOf(input);
if (callerSid && leadMarks.length && !leadMarks.some((m) => m.sid === callerSid)) allow();

const tool = input.tool_name || '';
if (!/^(SendMessage|Agent)$/.test(tool)) allow();

const ti = input.tool_input || {};
const raw = ti.prompt ?? ti.message ?? '';
const text = typeof raw === 'string' ? raw : String(raw?.reason || '');
if (!text) allow();


const ABSENCE_RE = new RegExp([
  '(?:has|have|carries|carry)\\s+no\\s+(?:evidence|proof|backing)',
  'no\\s+evidence\\s+(?:behind|for|of|exists)',
  '(?:was|were|is|are)\\s+not\\s+run',
  '(?:did|does)\\s+not\\s+(?:run|exist|fire)',
  'never\\s+(?:ran|fired|executed)',
  'must\\s+not\\s+be\\s+scored\\s+green',
  'zero\\s+hits', '\\b0\\s+hits',
  'no (?:evidence|run|hits)', 'never (?:ran|executed|verified)', 'zero hits', 'does not exist',
].join('|'), 'i');

const EXPECTATION_RE = new RegExp([
  'expected?\\s+(?:to\\s+be\\s+|value\\s+)?\\d+',
  'should\\s+be\\s+\\d+',
  'there\\s+(?:are|were)\\s+\\d+',
  'the\\s+count\\s+is\\s+\\d+',
  '(?:caps?|limits?|ceilings?|maximum)\\b[^.\\n]{0,24}?\\b(?:of|is|at|to)\\s+~?\\d+',
  'should be\\s*\\d+', 'at most\\s*~?\\d+', '(?:a total of|in total)\\s*\\d+\\s*(?:rows|items|places|lines)',
].join('|'), 'i');

const HEDGED_RE = new RegExp([
  '\\bUNVERIFIED\\b', '\\bI have not (?:run|measured|checked)\\b',
  '\\b(?:please )?(?:verify|determine|adjudicate|rule) whether\\b',
  '\\bdo not take (?:that|this|it) from me\\b',
  'UNVERIFIED|please judge|reproduce it yourself|do not copy this|I did not (?:run|measure)',
].join('|'), 'i');

const CLAIM_RE = new RegExp([
  'origin\\s+(?:now\\s+)?(?:equals|==|=|is)\\s+(?:your\\s+|the\\s+)?HEAD',
  'HEAD\\s+(?:equals|==|=|is)\\s+origin',
  'nothing\\s+will\\s+move\\s+under\\s+you',
  '(?:is|are)\\s+(?:not\\s+yet\\s+|un)pushed',
  'already\\s+pushed',
  'is\\s+an?\\s+ancestor\\s+of',
  'fast[- ]forward,?\\s+not\\s+a\\s+force',
  'origin\\s+(?:is\\s+)?(?:behind|ahead\\s+of|equal\\s+to)\\s+',
].join('|'), 'i');
const shas = new Set((text.match(/\b[0-9a-f]{7,40}\b/g) || []).map((s) => s.toLowerCase()));

if (!MEASURED_RE.test(text) && !HEDGED_RE.test(text)) {
  const hitAbsence = ABSENCE_RE.test(text) ? (text.match(ABSENCE_RE) || [''])[0] : '';
  const hitExpect = EXPECTATION_RE.test(text) ? (text.match(EXPECTATION_RE) || [''])[0] : '';
  if (hitAbsence || hitExpect) {
    const kind = hitAbsence ? 'an ABSENCE claim' : 'a number being used as an acceptance criterion';
    process.stdout.write(JSON.stringify({
      hookSpecificOutput: {
        hookEventName: 'PreToolUse',
        permissionDecision: 'deny',
        permissionDecisionReason:
          `BLOCKED: you are REPEATING a measurement rather than TAKING one\n\n`
          + `kind: ${kind}\nmatched: ${(hitAbsence || hitExpect).slice(0, 90)}\n`
          + `This message carries neither a measurement marker nor an unverified marker.\n\n`
          + `FIX, one of two, each a single line:\n`
          + `  1. print the measurement beside it — a command in backticks / \`rc=\` / \`file:line\` / an ISO date / "measured" / "I ran"\n`
          + `  2. mark it unverified — \`UNVERIFIED\` / "please judge whether X holds" / "do not copy this; reproduce it yourself"`,
      },
    }));
    process.exit(0);
  }
}

if (!CLAIM_RE.test(text)) allow();
if (shas.size >= 2) allow();

process.stdout.write(JSON.stringify({
  hookSpecificOutput: {
    hookEventName: 'PreToolUse',
    permissionDecision: 'deny',
    permissionDecisionReason:
      `BLOCKED: you are asserting a relationship between two refs without printing the values you measured\n\n` +
      `the assertion that matched: ${(text.match(CLAIM_RE) || [''])[0].slice(0, 80)}\n` +
      `SHA-shaped tokens in this message: ${shas.size} (2 or more are required)\n\n` +
      `FIX: measure it now, and print both values beside the assertion:\n` +
      `  git -C <main-checkout> fetch origin\n` +
      `  echo "origin=$(git rev-parse --short origin/<branch>) · HEAD=$(git -C <worktree> rev-parse --short HEAD)"\n` +
      `"origin equals your HEAD" goes stale; "\`origin=e121af91 · HEAD=cf8dca7f\`" does not.`,
  },
}));
process.exit(0);

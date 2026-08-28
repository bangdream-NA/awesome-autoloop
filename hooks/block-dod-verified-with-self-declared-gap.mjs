#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import { logDenial } from './lib/log-denial.mjs';

function allow() { process.stdout.write('{}'); process.exit(0); }

let raw = '';
try { raw = readFileSync(0, 'utf8'); } catch { allow(); }
let input;
try { input = JSON.parse(raw); } catch { allow(); }

const ti = input?.tool_input || {};
const file = String(ti.file_path || '');
if (!/BACKLOG[^/\\]*\.md$/i.test(file)) allow();

const parts = [ti.content, ti.new_string, ...(Array.isArray(ti.edits) ? ti.edits.map((e) => e?.new_string) : [])]
  .filter((x) => typeof x === 'string' && x);
if (!parts.length) allow();
const text = parts.join('\n');

if (!/DoD-VERIFIED/.test(text)) allow();

const GAP = [
  /\bis not (?:the same as|equivalent to)\b[^.\n]{0,24}\b(?:first-hand|actually|really|in reality)\b/i,
  /\b(?:no|not|never|could not|cannot|unable to)\b[^.\n]{0,12}\b(?:first-hand|actually|really)\b[^.\n]{0,16}\b(?:driven?|exercised?|observed?|walked?|reproduced?|verif(?:y|ied)|ran|run)\b/i,
  /\b(?:needs?|lacks?|requires?|missing)\b[^.\n]{0,12}\b(?:credentials?|an account|a login)\b[^.\n]{0,28}\b(?:none|does not have|not available in this session|this session has no)\b/i,
  /\bto close (?:the|that) gap\b/i,
  /\b(?:never|not)\b[^.\n]{0,12}\b(?:actually|really)\b[^.\n]{0,12}\b(?:triggered|executed|ran)\b/i,
  /\b(did not|never|could not|cannot)\b[^.\n]{0,40}\b(exercise|trigger|drive|observe|reproduce|actually (test|run))\b/i,
  /\bnot\b[^.\n]{0,20}\bend-to-end\b[^.\n]{0,30}\b(verified|tested)\b/i,
];

import { SCOPE_NARROWED_DOD_RE as NARROW } from './lib/backlog-grammar.mjs';

const narrowHit = text.match(NARROW);
if (narrowHit) {
  const q = narrowHit[0].slice(0, 90);
  const r =
    'BLOCKED: `DoD-VERIFIED` carries a SCOPE-NARROWING qualifier — that is writing down a third outcome.\n' +
    `Matched: "${q}"\n` +
    '\n' +
    'A DoD has exactly two honest outcomes: it walked ⇒ an **unscoped** `DoD-VERIFIED`; it broke ⇒ `DoD-FAILED` plus ' +
    '`dod-failed-at=`. **"Did part of it" is not a third one.** Handing the remainder honestly to another card is good practice, ' +
    'but it **does not change this card\u2019s verdict** — the card\u2019s scope is still larger than the part you verified.\n' +
    '\n' +
    'NOTE: this slips past the first layer of this gate, because that layer hunts for CONFESSIONS ("I never actually ran it"), and ' +
    'narrowing the scope **admits no gap at all** — it just makes the claim smaller. So it does not read like cutting corners, it ' +
    'reads like prudence. (Measured: `DoD-VERIFIED (scope = the delivered Phase 1a artifact; the other three gaps handed to …)` ' +
    'was written on a card whose own header said "four gaps", and once it landed the DoD gate went silent, because a scoped token ' +
    'still reads as "this card is settled".)\n' +
    'Pick one of three:\n' +
    '  1) finish the rest of this card, then write a **bare** `DoD-VERIFIED`.\n' +
    '  2) this card\u2019s DoD broke ⇒ write `DoD-FAILED` + `dod-failed-at=<ISO Z from date -u>`, file a remedy card ' +
    '(`dod-remedy-for=`) and register `dod-remedy-tracks=` back on the source card.\n' +
    '  3) this card\u2019s scope really WAS only the part you verified ⇒ change **the header\u2019s title and scope** so it says so, ' +
    'then write the bare token. Do not use a qualifier to retro-fit a larger title.\n' +
    '\n' +
    'Not caught (measured: zero false positives): `DoD-VERIFIED · …` followed by a PR, a sha, a date, or `(a real inbox receipt)` — ' +
    'that is EVIDENCE (evidence makes a claim stronger, a qualifier makes it weaker, and this gate only catches the second) · ' +
    'a `WRITE-JOURNEY-N/A` or `VISUAL-N/A` with a reason (including `docs-only`) · a POSITIVE scope statement ("this card\u2019s DoD does not include X, because …") · `DoD-FAILED` cards.';
  logDenial('block-dod-verified-with-self-declared-gap', 'scope-narrowed-dod-verified', q);
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: r },
  }));
  process.exit(0);
}

const hit = GAP.find((re) => re.test(text));
if (!hit) allow();

const sample = (text.match(hit) || [''])[0].slice(0, 90);
const reason =
  'BLOCKED: one card writes `DoD-VERIFIED` AND states that the core behaviour was never actually exercised — that is a fake DoD\n' +
  `The statement that matched: "${sample}"\n\n` +
  'FIX, one of three:\n' +
  '  1. do the missing run — usually cheaper than writing the paragraph explaining why it cannot be done; spend one command confirming that "cannot" is true first.\n' +
  '  2. do not write VERIFIED; write down what is still owed. An unfinished DoD is a normal state and does not need to be disguised as a finished one.\n' +
  '  3. the gap genuinely cannot be closed and the DoD never included it ⇒ state the scope as a POSITIVE ("this card\u2019s DoD does not include X, because …"),\n' +
  '     rather than subtracting from a VERIFIED claim.\n' +
  'Still fine: a `WRITE-JOURNEY-N/A` or `VISUAL-N/A` with a reason · stating a gap without claiming VERIFIED · `dod-failed-at=`.';

logDenial('block-dod-verified-with-self-declared-gap', 'fake-dod-verified-with-gap', sample);
process.stdout.write(JSON.stringify({
  hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: reason },
}));
process.exit(0);

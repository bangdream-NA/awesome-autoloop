#!/usr/bin/env node

import { readFileSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { autoLogOnDeny } from './lib/log-denial.mjs';
import { slugOf } from './lib/backlog-gate.mjs';
autoLogOnDeny('require-owes-cards-cleared-before-verified');

const allow = () => { process.stdout.write('{}'); process.exit(0); };
const deny = (reason) => {
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: reason },
  }));
  process.exit(0);
};

let input;
try { input = JSON.parse(readFileSync(0, 'utf8')); } catch { allow(); }

const ti = (input && input.tool_input) || {};
const filePath = String(ti.file_path || '');
if (!/BACKLOG[^/\\]*\.md$/i.test(filePath)) allow();

const introduced = [ti.content, ti.new_string, ...(Array.isArray(ti.edits) ? ti.edits.map((e) => e && e.new_string) : [])]
  .filter((s) => typeof s === 'string').join('\n');
const OWES_LINE = /^[ \t]*-[ \t]*owes-cards:[ \t]*(.*)$/gm;
const SLUG_LIST = /^(?:\(none\)|R-[A-Za-z0-9][A-Za-z0-9-]*(?:[ \t]*,[ \t]*R-[A-Za-z0-9][A-Za-z0-9-]*)*)$/;
{
  OWES_LINE.lastIndex = 0;
  let m;
  while ((m = OWES_LINE.exec(introduced || '')) !== null) {
    const body = (m[1] || '').trim();
    if (SLUG_LIST.test(body)) continue;
    deny(
      'BLOCKED: `- owes-cards:` holds slugs, never prose\n\n' +
      `  what was written: ${body.slice(0, 120)}${body.length > 120 ? '…' : ''}\n\n` +
      'FIX. Only two shapes are legal:\n' +
      '  · `- owes-cards: R-foo-bar, R-baz-qux`  <- comma-separated, each slug starts with `R-`\n' +
      '  · `- owes-cards: (none)`                <- nothing is owed\n' +
      'Reasoning and evidence go in `BACKLOG-detail-<date>.md`, with a `- prose-history:` pointer on the card.\n' +
      'What happened this turn goes in the op-log. The state of THIS card goes in `- log: <ISO Z> · <who was dispatched>`.',
    );
  }
}

if (!introduced || !/DoD-VERIFIED/.test(introduced)) allow();

const HEADER_SLUG_LEGACY = /^\s*(?:###\s+)?\[[A-Z-]+\]\s+(\S+)/;
const HEADER_SLUG = { exec: (line) => { const s = slugOf(line); return s ? [line, s] : HEADER_SLUG_LEGACY.exec(line); } };
const targets = new Set();
for (const line of introduced.split(/\r?\n/)) {
  if (!/DoD-VERIFIED/.test(line)) continue;
  const m = HEADER_SLUG.exec(line);
  if (m) targets.add(m[1]);
}
if (targets.size === 0) allow();

let corpus = '';
const known = new Set();
try {
  const dir = dirname(filePath);
  for (const f of readdirSync(dir)) {
    if (!/^BACKLOG.*\.md$/i.test(f)) continue;
    if (/\.bak/i.test(f)) continue;
    const txt = readFileSync(join(dir, f), 'utf8');
    corpus += '\n' + txt;
    for (const chunk of txt.split('\n### ')) {
      const h = chunk.split('\n')[0];
      const s = slugOf('### ' + h);
      const m = s ? [h, s]
        : (/^\[[A-Z-]+\]\s+(\S+)/.exec(h) || /^[^\s]*\s*(?:DONE|MERGED)?\s*(R-[a-z0-9.-]+)/.exec(h));
      if (m) known.add(m[1]);
    }
  }
} catch { allow(); }
if (known.size === 0) allow();

const bodyOf = (slug) => {
  for (const chunk of corpus.split('\n### ')) {
    const h = chunk.split('\n')[0];
    const s = slugOf('### ' + h) || (/^\[[A-Z-]+\]\s+(\S+)/.exec(h) || [])[1];
    if (s === slug) return chunk;
  }
  return '';
};

const OWES = /^\s*-\s*owes-cards:\s*(.+)$/m;
// The source language had one word for a board card, so a bare `card` could never mean a payment
// card or a card reader. English can, which is why the two senses this alternation gained over the
// original both carry a qualifier or a lookahead. hooks/tests/owes-cards-vocab.test.sh pairs each
// with the legitimate sentence it must stay silent on.
const ADMITS_DEFERRAL = new RegExp([
  'follow-up card', 'followup card', 'follow up card',
  'must be created',
  'needs? (?:its own|a separate|a follow-up|a new) card\\b',
  'wants a card of its own',
  'AC-\\d+\\([a-z]\\)',
  'defer(?:s|red)? to a card\\b',
  'hand(?:s|ed)?(?: it)?(?: off)? to a card\\b(?!\\s+(?:reader|number|holder|payment))',
].join('|'), 'i');

const TRACKS_FIELD = /dod-remedy-tracks=([^\s·]+)/;
const headerOf = (slug) => (bodyOf(slug).split('\n')[0] || '');
const introducedHeaderFor = (slug) => introduced.split(/\r?\n/)
  .find((l) => /DoD-VERIFIED/.test(l) && ((HEADER_SLUG.exec(l) || [])[1] === slug)) || '';

const P4_FIELD = /PURPOSE-REMEASURED\s*:\s*([^·\n]{20,})/;

const P4B_COUNT = /^\s*\[(\d+)\s*\/\s*(\d+)\]/;
const p4bVerdict = (val) => {
  const m = P4B_COUNT.exec(val || '');
  if (!m) return { ok: false, why: 'the value does not start with `[k/k]` — it never says how many assertions this card\u2019s problem contains' };
  const a = Number(m[1]); const b = Number(m[2]);
  if (!(a >= 1) || a !== b) return { ok: false, why: `\`[${m[1]}/${m[2]}]\` — the two numbers differ, or k < 1: it claims to cover ${m[1]} while the card has ${m[2]}` };
  const arrows = (val.match(/⇒/g) || []).length;
  if (arrows < a) return { ok: false, why: `it claims ${a} assertion(s), and the value holds only ${arrows} \`⇒\` reading(s)` };
  return { ok: true };
};

const problems = [];
for (const slug of targets) {
  const body = bodyOf(slug);
  const owes = OWES.exec(body);

  {
    const introduced = introducedHeaderFor(slug);
    const onDisk = headerOf(slug);
    const vLine = (introduced && P4_FIELD.test(introduced)) ? introduced
      : (P4_FIELD.test(onDisk || '') ? onDisk : (introduced || onDisk));
    const stated = (body.split('\n').filter((l) => /^-\s*problem\s*:/i.test(l)).join('\n') || '')
      .replace(/\s+/g, ' ').trim();
    if (!P4_FIELD.test(vLine)) {
      problems.push(
        `  · ${slug}\n` +
        `      the **card header** carries no \`PURPOSE-REMEASURED:\` — **nothing went back and measured the question this card itself asked**.\n` +
        `      NOTE: this judges the **card header**, not a verdict file under \`.claude/reviews/\` — do not edit those; a lead writing one is refused by a different gate.\n` +
        `      the line I actually read (first 160 chars): ${(vLine || '(empty — this write carries no `### ` header for this card, and there is none on disk)').slice(0, 160)}\n` +
        `      what the card says its problem is (first 100 chars): ${stated.slice(0, 100) || '(this card has no `- problem:` line — which is itself the defect: a card that cannot say what it is for has a DoD with no subject)'}\n` +
        `      **How to fix it**: take that number or that string to the live artifact **today**, measure it once, and write the command and the reading into the **card header**:\n` +
        `          \`PURPOSE-REMEASURED: <command or URL> ⇒ <today\u2019s reading>, against the value on the card\` (20+ chars; the value must stop before the next \`·\`)\n` +
        `      It changed ⇒ VERIFIED holds. It did not ⇒ this is not VERIFIED, it is \`DoD-FAILED\`.`,
      );
    } else {
      const val = (P4_FIELD.exec(vLine) || [])[1] || '';
      const v = p4bVerdict(val);
      if (!v.ok) {
        problems.push(
          `  · ${slug}\n` +
          `      \`PURPOSE-REMEASURED:\` is there, but it **does not say how many of the card\u2019s assertions it covers**: ${v.why}\n` +
          `      NOTE: a card\u2019s problem statement is often a CONJUNCTION. A question nobody asked and a question whose answer was fine\n` +
          `      read identically on the card. Measured once: a header asked whether the required fields were complete AND whether the list\n` +
          `      page needed an \`ItemList\`; only the second was measured, a 237-character value was written, and it passed. On a later\n` +
          `      check the first had a real gap on the one surface that is actually consumed.\n      **The card\u2019s own problem statement, verbatim** (first 300 chars):\n      ${(stated || headerOf(slug) || '').slice(0, 300)}\n` +
          `      **How to fix it**: count the measurable assertions in that sentence (call it k), then write\n` +
          `          \`PURPOSE-REMEASURED: [k/k] <assertion 1> ⇒ <today\u2019s reading 1>; <assertion 2> ⇒ <today\u2019s reading 2>…\`\n` +
          `      The two numbers must be equal, and there must be at least k \`⇒\` readings (the value still has to stop before the next \`·\`).\n` +
          `      NOTE: the gate does not know the real k — it only checks that your own two numbers agree and that there are enough readings. **You counted them, so you have to go and look.**`,
        );
      }
    }
  }

  const mt = TRACKS_FIELD.exec(introducedHeaderFor(slug) + '\n' + body);
  if (mt) {
    const tracks = mt[1].split(',').map((s) => s.trim()).filter((s) => /^R-[a-z0-9.-]+$/i.test(s));
    const openTracks = tracks.filter((t) => !targets.has(t) && !/DoD-VERIFIED/.test(headerOf(t)));
    if (openTracks.length) {
      problems.push(
        `  · ${slug}\n` +
        `      \`dod-remedy-tracks=\` names ${tracks.length} remedy card(s), and **${openTracks.length} of them have not finished their own DoD**:\n` +
        openTracks.map((t) => `        - ${t} — current header: ${(headerOf(t) || '(no such card on the board)').slice(0, 96)}`).join('\n') +
        `\n      A source card must not close ahead of its remedy tracks — the moment it is archived, that chain has no live supervision left.`,
      );
    }
  }

  if (owes) {
    const named = owes[1].split(/[,\s·]+/).map((s) => s.trim()).filter((s) => /^R-[a-z0-9.-]+$/i.test(s));
    const missing = named.filter((s) => !known.has(s));
    if (missing.length) {
      problems.push(
        `  · ${slug}\n` +
        `      \`- owes-cards:\` names ${named.length} follow-up card(s), and **${missing.length} of them do not exist on the board**:\n` +
        missing.map((s) => `        - ${s}`).join('\n') +
        `\n      (compared on each card\u2019s own first token, across the active board plus every archive: ${known.size} known cards)`,
      );
    }
  } else if (ADMITS_DEFERRAL.test(body)) {
    const quote = (body.match(ADMITS_DEFERRAL) || [''])[0];
    problems.push(
      `  · ${slug}\n` +
      `      The card body admits it handed work off (it matched "${quote}"), but there is **no \`- owes-cards:\` field**.\n` +
      `      A promise with no named carrier ⇒ the moment this card is archived those follow-ups vanish, leaving no trace on the board.`,
    );
  }
}
if (problems.length === 0) allow();

deny(
  `BLOCKED: OWES-CARDS is not cleared, so DoD-VERIFIED cannot be written\n\n` +
  problems.join('\n\n') + '\n\n' +
  `FIX, one of three:\n` +
  `  1. create the missing cards (that IS the work being owed)\n` +
  `  2. one of them really is unnecessary ⇒ delete it from \`- owes-cards:\`, **and say why in the same write**\n` +
  `  3. nothing was ever owed ⇒ add the line \`- owes-cards: (none)\`\n` +
  `Deleting the whole \`- owes-cards:\` line does not work — P2 catches it immediately.\n\n` +
  `If what was reported is \`dod-remedy-tracks=\` (P3) there are exactly two ways out: (1) finish the remedy cards\u2019 DoD, then come back and close the source card; ` +
  `(2) close the source card and the remedy cards together ⇒ **write \`DoD-VERIFIED\` on BOTH headers in the same write**.\n` +
  `Do not delete \`dod-remedy-tracks=\` from the card header.`,
);

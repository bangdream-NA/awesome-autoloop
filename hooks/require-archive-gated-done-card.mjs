#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import { loadWriteToolLines, cardAuthoredHere } from './lib/authored-here.mjs';
import { stripGateBracket, GATE_BLOCKER_TOKEN_RE } from './lib/backlog-gate.mjs';
import { autoLogOnDeny } from './lib/log-denial.mjs';
import { projectPaths } from './lib/is-autoloop-lead.mjs';
import { isAutoloopSession } from './lib/is-autoloop-lead.mjs';
autoLogOnDeny('require-archive-gated-done-card');

let stdin = {};
try { stdin = JSON.parse(readFileSync(0, 'utf8') || '{}'); } catch { stdin = {}; }
const tp = String(stdin.transcript_path || '').replace(/\\/g, '/');
if (tp && !isAutoloopSession(stdin)) { process.stdout.write('{}'); process.exit(0); }

const BOARD_PATH = process.env.AAL_BACKLOG || projectPaths()?.board || '';
let board = '';
try { board = readFileSync(BOARD_PATH, 'utf8'); } catch { process.stdout.write('{}'); process.exit(0); }

const cards = board.split(/\n(?=### \[)/).filter((c) => /^### \[/.test(c));

const isShipped = (c) =>
  /(?:MERGED|merged)\s*#?\s*\d+|#\d+\s*(?:MERGED|@[0-9a-f]{7})|code[-\s]?shipped|code[-\s]?complete|LIVE on (?:the box|prod)|deployed|deploy\s*(?:DONE|done|complete)/i.test(stripGateBracket(c));

const ESCAPE_PROSE_RE = /STILL-GATED:|blocker[-\s]?id|§B-\d|reachable-pending|§15|board converge|2nd-pass|no-live-occurrence|cold-repro|waiting for it to actually occur|premise\s*(?:cannot|could not) be reproduced|Dependabot|dep[-\s]?hygiene|external dep|EMPTY_SLUG|standing\s*(?:EPIC|obligation)|#11-exception/i;
const ESCAPE_VERDICT_RE = /\b(?:FAKE|STALE|PHANTOM|WONTFIX|SUPERSEDED)\b/;

const TERMINAL_RE = /DoD-VERIFIED|dod-verified-at=|DoD-OBSOLETE|obsolete-at=/;
const terminalToken = (c) => (c.match(TERMINAL_RE) || [null])[0];

const isEscaped = (c) =>
  !terminalToken(c)
  && (ESCAPE_PROSE_RE.test(c) || ESCAPE_VERDICT_RE.test(c) || GATE_BLOCKER_TOKEN_RE.test(c));

const WTL = loadWriteToolLines(tp);
const flagged = [];
for (const c of cards) {
  const header = c.split('\n')[0];
  if (!/^### \[[^\]]*(?:USER-GATED|BLOCKED)/.test(header)) continue;
  if (!isShipped(c)) continue;
  if (isEscaped(c)) continue;
  if (!cardAuthoredHere(WTL, c)) continue;
  const slug = (header.match(/R-[a-z0-9-]+/) || ['(card)'])[0];
  const term = terminalToken(c);
  flagged.push(term ? `${slug} (the card carries ${term}; a terminal outcome cannot also be gated)` : slug);
}

if (!flagged.length) { process.stdout.write('{}'); process.exit(0); }

process.stdout.write(JSON.stringify({
  decision: 'block',
  reason:
    `BLOCKED: a card that has SHIPPED is still badged [BLOCKED] / [USER-GATED]\n\n`
    + `A card with a parenthesis after it (a terminal token) can only take route 1; no escape word releases it.\n`
    + `Without the parenthesis, route 1 or route 2 both work.\n\n`
    + `1. archive it: cut the WHOLE card into .claude/BACKLOG-archive-<date>.md and set the badge to [DONE].\n`
    + `   The active board only accepts {QUEUED, IN-DEV, REVIEW, BLOCKED, USER-GATED}.\n`
    + `2. still moving ⇒ flip it to [IN-DEV], or write an escape word.\n\n`
    + `Escape words, verbatim: STILL-GATED: <reason> · reachable-pending ·\n`
    + `#11-exception · no-live-occurrence · cold-repro · dep-hygiene · standing EPIC ·\n`
    + `FAKE / STALE / PHANTOM / WONTFIX / SUPERSEDED (uppercase; case-sensitive).\n`
    + `NOT escape words: VISUAL-N/A · phantom-gate · Stale.\n\ncards: ${flagged.join(', ')}`,
}));
process.exit(0);

#!/usr/bin/env node

import { readFileSync } from 'node:fs';
import { logDenial } from './lib/log-denial.mjs';

const MAX_BULLET = Number(process.env.OPLOG_MAX_BULLET_CHARS || 600);

let stdin = {};
try {
  stdin = JSON.parse(readFileSync(0, 'utf8') || '{}');
} catch {
  process.stdout.write('{}');
  process.exit(0);
}

const tool = String(stdin.tool_name || '');
const input = stdin.tool_input || {};
const filePath = String(
  input.file_path || input.path || input.filePath || '',
).replace(/\\/g, '/');

if (!/autoloop-log-.*\.md$/i.test(filePath)) {
  process.stdout.write('{}');
  process.exit(0);
}

function collectCandidateLines(ti) {
  const lines = [];
  if (typeof ti.content === 'string' && ti.content.length) {
    for (const l of ti.content.split(/\r?\n/)) lines.push(l);
  }
  if (typeof ti.new_string === 'string' && ti.new_string.length) {
    for (const l of ti.new_string.split(/\r?\n/)) lines.push(l);
  }
  if (Array.isArray(ti.edits)) {
    for (const e of ti.edits) {
      if (typeof e?.new_string === 'string') {
        for (const l of e.new_string.split(/\r?\n/)) lines.push(l);
      }
    }
  }
  return lines;
}

const lines = collectCandidateLines(input);
if (!lines.length) {
  process.stdout.write('{}');
  process.exit(0);
}

const violations = [];
for (const raw of lines) {
  if (!/^\s*-\s+/.test(raw)) continue;
  const line = raw.replace(/^\s+/, '');
  const body = line.slice(2);

  if (body.length > MAX_BULLET) {
    violations.push(
      `len=${body.length}>${MAX_BULLET}: ${body.slice(0, 80)}…`,
    );
    continue;
  }
  const hasGlue =
    / · /.test(body) ||
    /\d{1,2}:\d{2}x?Z?\s*·/.test(body) ||
    /batch\s*\d+\)?\s*·/i.test(body) ||
    /^\*\*[^*]+\*\*\s*·/.test(body);
  if (!hasGlue) {
    const looksLikeLedger =
      /\(batch\s*\d+\)/i.test(body) ||
      /MERGED|merge|PR\s*#\d+|#\d{2,4}\b|DoD|dispatch|server-op|install|deploy/.test(
        body,
      );
    if (looksLikeLedger) {
      violations.push(`missing ' · ' glue on ledger bullet: ${body.slice(0, 80)}…`);
      continue;
    }
  }
  const midDotCount = (body.match(/·/g) || []).length;
  const hasArrow = /→|->|⇒/.test(body);
  const hasProof = /proof|#\d{2,4}\b|@`?[0-9a-f]{7,}/i.test(body);
  if (midDotCount < 1 && !hasArrow && !hasProof) {
    if (body.length > 120) {
      violations.push(
        `no feature·problem·proof / action→result shape: ${body.slice(0, 80)}…`,
      );
    }
  }
}

if (!violations.length) {
  process.stdout.write('{}');
  process.exit(0);
}

const reason =
  `HARD GATE (op-log format): autoloop-log bullet row(s) violate the fixed format. ` +
  `Canonical row = \`- YYYY-MM-DD HH:MMxZ · **title (batch N)**: feature·problem·proof\` ` +
  `(or action·result·next). Rules: (1) ONE bullet = ONE ledger action; ` +
  `(2) must use ' · ' glue after the timestamp/title; (3) body ≤ ${MAX_BULLET} chars ` +
  `(essay bullets are the 2026-07-18/19 drift class — historical healthy mean ~400); ` +
  `(4) include · separators or → / proof / #PR. ` +
  `Violations: ${violations.slice(0, 3).join(' | ')}. ` +
  `Rewrite the row concise, then re-apply. (oplog-turn-reminder already asked for this; ` +
  `this gate enforces it. USER 2026-07-20.)`;

logDenial('require-oplog-row-format', 'oplog-row-format', violations.slice(0, 3).join(' ; '));
process.stdout.write(
  JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason: reason,
    },
  }),
);
process.exit(0);

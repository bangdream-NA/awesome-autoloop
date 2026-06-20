#!/usr/bin/env node
// PreToolUse(Edit|Write) — block writing a NEW BACKLOG card that lacks the SOP skeleton, so the
// board stays fixed-format GOING FORWARD ("if the format is wrong, block it and make them write it
// per the SOP").
//
// Scope (deliberately narrow — a write-gate that over-blocks would WEDGE the only task board, so this
// is migration-TOLERANT + fail-OPEN):
//   • Fires on Edit/Write to ANY project's `.claude/BACKLOG.md` (path-generic).
//   • Checks ONLY cards whose NAME is NEW (not already on the board) — i.e. cards this write CREATES.
//     Edits to existing cards (status change, log append, marker edit, archiving) are NEVER blocked,
//     even if that card is pre-SOP debt (migration-tolerant; fix-as-you-touch).
//   • A new card must carry the SKELETON — `aliases:` + `problem:` + `fix:` lines + a whitelisted
//     status. Content may be a `<TODO>` placeholder (skeleton enforced, not content). The field
//     greps accept either the English template labels or their legacy Chinese equivalents.
//   • fail-OPEN: any parse/IO uncertainty → allow (a hook bug must not block board updates).
import { readFileSync } from 'node:fs';

const STATUS_WL = ['QUEUED', 'IN-DEV', 'REVIEW', 'BLOCKED', 'USER-GATED'];
const norm = (s) => String(s || '').toLowerCase().replace(/^feat\//, '').replace(/^t-\d+\s+/, '').replace(/[`*~]/g, '').trim();
const HDR = /^###\s+\[([^\]]+)\]\s+(.+)$/;
const cardName = (headerRest) => norm(headerRest.split('·')[0].split('(')[0].trim());

// parse a text into [{status, name, headerRest, block}]
function parseCards(text) {
  const lines = String(text).split(/\r?\n/);
  const out = [];
  for (let i = 0; i < lines.length; i++) {
    const m = lines[i].match(HDR);
    if (!m) continue;
    const body = [lines[i]];
    for (let j = i + 1; j < lines.length && !/^#{2,3}\s/.test(lines[j]); j++) body.push(lines[j]);
    out.push({ status: m[1], name: cardName(m[2]), headerRest: m[2], block: body.join('\n') });
  }
  return out;
}

function main() {
  let input;
  try { input = JSON.parse(readFileSync(0, 'utf8')); } catch { process.exit(0); } // fail-open
  const tool = input.tool_name || '';
  if (tool !== 'Edit' && tool !== 'Write') process.exit(0);
  const ti = input.tool_input || {};
  const fp = String(ti.file_path || '');
  if (!/[/\\]BACKLOG\.md$/.test(fp)) process.exit(0);              // only the live board file (any project)

  // current on-disk board (for "what names already exist")
  let current = '';
  try { current = readFileSync(fp, 'utf8'); } catch { current = ''; } // new file → everything is new

  // RESULT text after this write (so a card's FULL block is visible even for a partial Edit)
  let result;
  if (tool === 'Write') {
    result = String(ti.content || '');
  } else {
    const os = String(ti.old_string ?? ''), ns = String(ti.new_string ?? '');
    if (!current.includes(os)) process.exit(0);                    // can't locate edit → fail-open
    result = ti.replace_all ? current.split(os).join(ns) : current.replace(os, ns);
  }

  const existing = new Set(parseCards(current).map((c) => c.name));
  const newCards = parseCards(result).filter((c) => !existing.has(c.name));
  if (newCards.length === 0) process.exit(0);                      // no new card → nothing to enforce

  const bad = [];
  for (const c of newCards) {
    const miss = [];
    if (!STATUS_WL.includes(c.status)) miss.push(`status [${c.status}] not in {${STATUS_WL.join('/')}}`);
    if (!/(?:aliases|别名)\s*[:：]/.test(c.block)) miss.push('aliases:');
    if (!/(?:problem|问题)\s*[:：]/.test(c.block)) miss.push('problem:');
    if (!/(?:fix|修复)\s*[:：]/.test(c.block)) miss.push('fix:');
    if (miss.length) bad.push({ name: c.headerRest.slice(0, 50), miss });
  }
  if (bad.length === 0) process.exit(0);                           // all new cards conform → allow

  const list = bad.map((b) => `  • "${b.name}" — missing: ${b.miss.join(', ')}`).join('\n');
  const reason = `BLOCKED: writing ${bad.length} NEW BACKLOG card(s) that don't match the SOP skeleton:\n${list}\n\n` +
    `Every NEW card must be (content may be a "<TODO>" placeholder — the skeleton is what's enforced):\n` +
    `### [STATUS] R-<wave> · P<n>          (STATUS ∈ ${STATUS_WL.join('/')})\n` +
    `- aliases: r-<wave>\n- problem: <what's wrong>\n- fix: <the fix + acceptance criteria>\n` +
    `- log:\n    - YYYY-MM-DD · REGISTERED · <who> · proof=<evidence> · next=<next action>\n\n` +
    `(Editing existing cards is never blocked — this gates only newly-created cards.)`;
  process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: reason } }));
}
try { main(); } catch { process.exit(0); } // fail-OPEN on any unexpected error

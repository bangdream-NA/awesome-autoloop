#!/usr/bin/env node
// Board resolution: AAL_AUDITGATE_BACKLOG (test-only override) -> AAL_BACKLOG -> CLAUDE_PROJECT_DIR ->
import { readFileSync } from 'node:fs';
import path from 'node:path';

let raw = '';
try { raw = readFileSync(0, 'utf8'); } catch {}
let input;
try { input = JSON.parse(raw); } catch { process.exit(0); }

const ti = (input && input.tool_input) || {};

function extractMetaLiteral(src) {
  if (!src) return null;
  const m = src.match(/export\s+const\s+meta\s*=\s*\{/);
  if (!m) return null;
  let i = m.index + m[0].length - 1;
  let depth = 0, out = '', inStr = null, esc = false;
  for (; i < src.length; i++) {
    const ch = src[i];
    out += ch;
    if (esc) { esc = false; continue; }
    if (inStr) {
      if (ch === '\\') esc = true;
      else if (ch === inStr) inStr = null;
      continue;
    }
    if (ch === "'" || ch === '"' || ch === '`') { inStr = ch; continue; }
    if (ch === '{') depth++;
    else if (ch === '}') { depth--; if (depth === 0) return out; }
  }
  return null;
}

let script = typeof ti.script === 'string' ? ti.script : '';
if (!script && typeof ti.scriptPath === 'string') {
  try { script = readFileSync(ti.scriptPath, 'utf8'); } catch {}
}

const meta = extractMetaLiteral(script);
const declared = [ti.name, ti.description, ti.title, ti.scriptPath, meta]
  .filter(Boolean)
  .join('\n')
  .toLowerCase();
const body = script.toLowerCase();

const AUDIT_RE = /\baudit\b|categorized|full-site/;
const intentBlob = script && meta === null ? declared + '\n' + body : declared;
if (!AUDIT_RE.test(intentBlob)) process.exit(0);

function deny(reason) {
  console.log(JSON.stringify({
    hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: reason },
  }));
  process.exit(0);
}

const BACKLOG = process.env.AAL_AUDITGATE_BACKLOG
  || process.env.AAL_BACKLOG
  || (process.env.CLAUDE_PROJECT_DIR ? path.join(process.env.CLAUDE_PROJECT_DIR, '.claude', 'BACKLOG.md') : path.join(process.cwd(), '.claude', 'BACKLOG.md'));
let board = null;
try { board = readFileSync(BACKLOG, 'utf8'); } catch {}
if (board === null) {
  deny(`AUDIT-GATE: an audit-shaped Workflow was requested but the active BACKLOG.md (${BACKLOG}) could not be read to verify the board is clear -- FAIL-CLOSED. Set AAL_BACKLOG (or run from the project dir with a .claude/BACKLOG.md), then retry.`);
}

const actionable = board.match(/^### \[(QUEUED|IN-DEV|REVIEW)\]/gm) || [];
if (actionable.length === 0) process.exit(0);

const headers = (board.match(/^### \[(QUEUED|IN-DEV|REVIEW)\][^\n]*/gm) || [])
  .slice(0, 8)
  .map((h) => h.replace(/^### /, '').trim())
  .join('\n  - ');

deny(
  `AUDIT-GATE (clear the board before a NEW audit -- see the pipeline-discipline "clear the board before a NEW audit" rule): this audit-shaped Workflow is BLOCKED -- the active BACKLOG has ${actionable.length} actionable card(s) ([QUEUED]/[IN-DEV]/[REVIEW]). A fresh full-site/categorized audit runs ONLY on a CLEARED board; launching it now piles new findings on an un-converged board and the "loop until no bugs" goal never converges. FINISH or ARCHIVE these first ([USER-GATED]/[BLOCKED]/deferred do NOT count, but [QUEUED]/[IN-DEV]/[REVIEW] DO):\n  - ${headers}\nThe audit is the LAST step on an empty board, not an any-time impulse. (If a card is genuinely parked, re-tag it [USER-GATED]/[BLOCKED] so it stops counting.)`
);

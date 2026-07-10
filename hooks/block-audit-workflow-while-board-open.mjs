#!/usr/bin/env node
// block-audit-workflow-while-board-open.mjs
// PreToolUse(Workflow): DENY an audit-shaped Workflow while the project's ACTIVE BACKLOG.md still has
// actionable [QUEUED]/[IN-DEV]/[REVIEW] cards. A fresh full-site/categorized audit must run ONLY on a
// cleared board (the "clear the board before a NEW audit" rule in pipeline-discipline.md) -- else fresh
// findings pile on an un-converged board and "loop until no bugs" never converges.
//
// Intent is judged ONLY on the Workflow's DECLARED identity (name/description/title/scriptPath + the
// `export const meta = {...}` literal), NOT the whole script blob -- a DATA filename quoted in the
// script body (e.g. an "audit" log path) must not misclassify a non-audit run (rule-8: judge the
// declared ACTION, not incidental payload text). Whole-script fallback ONLY when a script exists but
// its meta literal can't be parsed (a missing meta is itself anomalous -- you can't dodge by omitting it).
//
// Board resolution: AAL_AUDITGATE_BACKLOG (test-only override) -> AAL_BACKLOG -> CLAUDE_PROJECT_DIR ->
// cwd. Fail-CLOSED (deny) for an audit-shaped run whose board can't be read -- a board-integrity gate
// that can't verify must not silently allow. The .sh wrapper's activation guard scopes this to an
// autoloop project; a non-audit Workflow always no-ops.
import { readFileSync } from 'node:fs';
import path from 'node:path';

let raw = '';
try { raw = readFileSync(0, 'utf8'); } catch {}
let input;
try { input = JSON.parse(raw); } catch { process.exit(0); } // unparseable -> not our case -> allow

const ti = (input && input.tool_input) || {};

// Extract the `export const meta = {...}` pure-literal block via brace matching
// (string-aware so a '}' inside a quoted value doesn't close early).
function extractMetaLiteral(src) {
  if (!src) return null;
  const m = src.match(/export\s+const\s+meta\s*=\s*\{/);
  if (!m) return null;
  let i = m.index + m[0].length - 1; // index of the opening '{'
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
  return null; // unbalanced -> extraction failed
}

let script = typeof ti.script === 'string' ? ti.script : '';
if (!script && typeof ti.scriptPath === 'string') {
  try { script = readFileSync(ti.scriptPath, 'utf8'); } catch {} // unreadable -> classify on declared fields only
}

const meta = extractMetaLiteral(script);
const declared = [ti.name, ti.description, ti.title, ti.scriptPath, meta]
  .filter(Boolean)
  .join('\n')
  .toLowerCase();
const body = script.toLowerCase();

// audit-shaped? (target = a full-site / categorized audit fan-out) -- judged on the DECLARED identity;
// whole-script fallback only when a script exists but its meta didn't parse.
const AUDIT_RE = /\baudit\b|categorized|full-site/;
const intentBlob = script && meta === null ? declared + '\n' + body : declared;
if (!AUDIT_RE.test(intentBlob)) process.exit(0);

function deny(reason) {
  console.log(JSON.stringify({
    hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: reason },
  }));
  process.exit(0);
}

// board resolution (generic -- no hardcoded project). AAL_AUDITGATE_BACKLOG is a TEST-ONLY override.
const BACKLOG = process.env.AAL_AUDITGATE_BACKLOG
  || process.env.AAL_BACKLOG
  || (process.env.CLAUDE_PROJECT_DIR ? path.join(process.env.CLAUDE_PROJECT_DIR, '.claude', 'BACKLOG.md') : path.join(process.cwd(), '.claude', 'BACKLOG.md'));
let board = null;
try { board = readFileSync(BACKLOG, 'utf8'); } catch {}
if (board === null) {
  deny(`AUDIT-GATE: an audit-shaped Workflow was requested but the active BACKLOG.md (${BACKLOG}) could not be read to verify the board is clear -- FAIL-CLOSED. Set AAL_BACKLOG (or run from the project dir with a .claude/BACKLOG.md), then retry.`);
}

// Actionable = [QUEUED] / [IN-DEV] / [REVIEW]. [USER-GATED]/[BLOCKED] are parked by design and do NOT block.
const actionable = board.match(/^### \[(QUEUED|IN-DEV|REVIEW)\]/gm) || [];
if (actionable.length === 0) process.exit(0); // board clear -> the audit is allowed (it IS the last step on an empty board)

// Surface the offending card headers so the runner knows what to finish first.
const headers = (board.match(/^### \[(QUEUED|IN-DEV|REVIEW)\][^\n]*/gm) || [])
  .slice(0, 8)
  .map((h) => h.replace(/^### /, '').trim())
  .join('\n  - ');

deny(
  `AUDIT-GATE (clear the board before a NEW audit -- see the pipeline-discipline "clear the board before a NEW audit" rule): this audit-shaped Workflow is BLOCKED -- the active BACKLOG has ${actionable.length} actionable card(s) ([QUEUED]/[IN-DEV]/[REVIEW]). A fresh full-site/categorized audit runs ONLY on a CLEARED board; launching it now piles new findings on an un-converged board and the "loop until no bugs" goal never converges. FINISH or ARCHIVE these first ([USER-GATED]/[BLOCKED]/deferred do NOT count, but [QUEUED]/[IN-DEV]/[REVIEW] DO):\n  - ${headers}\nThe audit is the LAST step on an empty board, not an any-time impulse. (If a card is genuinely parked, re-tag it [USER-GATED]/[BLOCKED] so it stops counting.)`
);

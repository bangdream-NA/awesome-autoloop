#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import { autoLogOnDeny } from './lib/log-denial.mjs';
import { projectPaths } from './lib/is-autoloop-lead.mjs';
autoLogOnDeny('block-workflow-pipeline-bypass');

const PIPELINE_TYPES = new Set([
  'planner',
  'uiux-designer',
  'designer',
  'architect',
  'developer',
  'plan-reviewer',
  'code-reviewer',
]);
const AUDIT_RE = /\baudit\b|categoriz(?:ed|ation)|full-site/i;

function readStdin() {
  try { return readFileSync(0, 'utf8'); } catch { return ''; }
}

function readScript(toolInput) {
  if (typeof toolInput.script === 'string') return toolInput.script;
  if (typeof toolInput.scriptPath !== 'string') return '';
  try { return readFileSync(toolInput.scriptPath, 'utf8'); } catch { return ''; }
}

function extractMetaLiteral(source) {
  const match = source.match(/export\s+const\s+meta\s*=\s*\{/);
  if (!match) return '';
  let depth = 0;
  let quote = null;
  let escaped = false;
  let out = '';
  for (let i = match.index + match[0].length - 1; i < source.length; i += 1) {
    const ch = source[i];
    out += ch;
    if (escaped) { escaped = false; continue; }
    if (quote) {
      if (ch === '\\') escaped = true;
      else if (ch === quote) quote = null;
      continue;
    }
    if (ch === "'" || ch === '"' || ch === '`') { quote = ch; continue; }
    if (ch === '{') depth += 1;
    if (ch === '}') {
      depth -= 1;
      if (depth === 0) return out;
    }
  }
  return '';
}

function skipQuotedOrComment(source, i) {
  const ch = source[i];
  if (ch === "'" || ch === '"' || ch === '`') {
    const quote = ch;
    i += 1;
    for (; i < source.length; i += 1) {
      if (source[i] === '\\') { i += 1; continue; }
      if (source[i] === quote) return i + 1;
    }
    return source.length;
  }
  if (ch === '/' && source[i + 1] === '/') {
    i += 2;
    while (i < source.length && source[i] !== '\n') i += 1;
    return i;
  }
  if (ch === '/' && source[i + 1] === '*') {
    const end = source.indexOf('*/', i + 2);
    return end < 0 ? source.length : end + 2;
  }
  return i;
}

function identifierAt(source, i, identifier) {
  if (!source.startsWith(identifier, i)) return false;
  const before = source[i - 1] || '';
  const after = source[i + identifier.length] || '';
  return !/[A-Za-z0-9_$]/.test(before) && !/[A-Za-z0-9_$]/.test(after);
}

function skipSpace(source, i) {
  while (i < source.length && /\s/.test(source[i])) i += 1;
  return i;
}

function findCallEnd(source, openParen) {
  let depth = 0;
  for (let i = openParen; i < source.length; i += 1) {
    const skipped = skipQuotedOrComment(source, i);
    if (skipped !== i) { i = skipped - 1; continue; }
    if (source[i] === '(') depth += 1;
    else if (source[i] === ')') {
      depth -= 1;
      if (depth === 0) return i;
    }
  }
  return -1;
}

function secondArgument(source, openParen, closeParen) {
  let depth = 1;
  for (let i = openParen + 1; i < closeParen; i += 1) {
    const skipped = skipQuotedOrComment(source, i);
    if (skipped !== i) { i = skipped - 1; continue; }
    if ('([{'.includes(source[i])) depth += 1;
    else if (')]}'.includes(source[i])) depth -= 1;
    else if (source[i] === ',' && depth === 1) return source.slice(i + 1, closeParen);
  }
  return '';
}

function parsePipelineAgentType(options) {
  for (let i = 0; i < options.length; i += 1) {
    const skipped = skipQuotedOrComment(options, i);
    if (skipped !== i) { i = skipped - 1; continue; }
    if (!identifierAt(options, i, 'agentType')) continue;
    let j = skipSpace(options, i + 'agentType'.length);
    if (options[j] !== ':') continue;
    j = skipSpace(options, j + 1);
    const quote = options[j];
    if (quote !== "'" && quote !== '"') continue;
    j += 1;
    let value = '';
    for (; j < options.length; j += 1) {
      if (options[j] === '\\') { j += 1; if (j < options.length) value += options[j]; continue; }
      if (options[j] === quote) break;
      value += options[j];
    }
    const type = value.toLowerCase();
    return PIPELINE_TYPES.has(type) ? type : null;
  }
  return null;
}

function inspectAgentCalls(source) {
  let hasAgentCall = false;
  const pipelineTypes = new Set();
  for (let i = 0; i < source.length; i += 1) {
    const skipped = skipQuotedOrComment(source, i);
    if (skipped !== i) { i = skipped - 1; continue; }
    if (!identifierAt(source, i, 'agent')) continue;
    const openParen = skipSpace(source, i + 'agent'.length);
    if (source[openParen] !== '(') continue;
    hasAgentCall = true;
    const closeParen = findCallEnd(source, openParen);
    if (closeParen < 0) continue;
    const type = parsePipelineAgentType(secondArgument(source, openParen, closeParen));
    if (type) pipelineTypes.add(type);
    i = closeParen;
  }
  return { hasAgentCall, pipelineTypes: [...pipelineTypes] };
}

function deny(reason) {
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason: reason,
    },
  }));
  process.exit(0);
}

let payload = {};
try { payload = JSON.parse(readStdin() || '{}'); } catch { process.exit(0); }
if (payload.tool_name !== 'Workflow') process.exit(0);

const toolInput = payload.tool_input || {};
const source = readScript(toolInput);
const meta = extractMetaLiteral(source);
const declared = [toolInput.name, toolInput.description, toolInput.title, toolInput.scriptPath, meta]
  .filter(Boolean)
  .join('\n');
const target = `${declared}\n${source}`;
const PROJ = process.env.AAL_PROJECT_NAME || (projectPaths()?.repo || '').replace(/\\/g, '/').split('/').filter(Boolean).pop() || '';
if (!PROJ || !new RegExp('\\b' + PROJ.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '\\b', 'i').test(target)) process.exit(0);

const { hasAgentCall, pipelineTypes } = inspectAgentCalls(source);
if (!hasAgentCall) process.exit(0);

if (pipelineTypes.length > 0) {
  deny(
    `BLOCKED: WORKFLOW PIPELINE-BYPASS GATE: this project's Workflow statically dispatches agentType=${pipelineTypes.join(', ')}. ` +
    'Planner/designer/architect/developer/reviewer work MUST use the Agent tool with team_name, name, and subagent_type so the Agent-only backlog, premise, stall, reviewer-ownership, and handoff gates run. ' +
    'Use Agent(...) for that role; Workflow may not substitute for a pipeline dispatch.'
  );
}

if (!AUDIT_RE.test(declared)) {
  deny(
    'BLOCKED: WORKFLOW PIPELINE-BYPASS GATE: this non-audit Workflow starts agent(...) for this project. ' +
    'This project must dispatch named implicit-team agents through Agent({team_name, name, subagent_type}); Workflow has no equivalent lifecycle or Agent-only gates. ' +
    'For a genuine full-site audit, declare audit intent in export const meta and the separate audit-board gate will verify that BACKLOG is clear.'
  );
}

process.exit(0);

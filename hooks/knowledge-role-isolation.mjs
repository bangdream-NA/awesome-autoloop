#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import { logDenial } from './lib/log-denial.mjs';

const ROLES = new Set(['planner', 'plan-reviewer', 'uiux-designer', 'architect', 'developer', 'code-reviewer']);

const allow = () => { process.stdout.write('{}'); process.exit(0); };

let stdin = {};
try { stdin = JSON.parse(readFileSync(0, 'utf8') || '{}'); } catch { allow(); }

const TOOL = String(stdin.tool_name || '');
if (!/^(Write|Edit|MultiEdit)$/.test(TOOL)) allow();

const TI = stdin.tool_input || {};
const fp = String(TI.file_path || '').replace(/\\/g, '/');
if (!fp) allow();

const m = fp.match(/(?:^|\/)knowledge\/([^/]+)\/[^/]+$/);
if (!m) allow();
const dir = m[1];

if (dir === 'common') allow();
if (!ROLES.has(dir)) allow();

const actor = String(
  process.env.AAL_AGENT_TYPE
  || process.env.CLAUDE_AGENT_TYPE
  || stdin.subagent_type
  || (stdin.agent && stdin.agent.type)
  || '',
).trim();

if (!actor) allow();
if (actor === dir) allow();

const reason =
  `BLOCKED: a ${actor} may not write into knowledge/${dir}/. `
  + `A role writes only into its OWN directory, so the next agent of a role can trust that everything under its name was written by that role. `
  + `FIX, one of two: write to knowledge/${actor}/${fp.split('/').pop()} instead, `
  + `or, if this belongs to every role, write it to knowledge/common/ and append one line to knowledge/common/INDEX.md in the form: - [<file>](<file>) - <one line>.`;

logDenial('knowledge-role-isolation', 'cross-role-knowledge-write', `${actor} -> knowledge/${dir}/`);
process.stdout.write(JSON.stringify({
  hookSpecificOutput: {
    hookEventName: 'PreToolUse',
    permissionDecision: 'deny',
    permissionDecisionReason: reason,
  },
}));
process.exit(0);

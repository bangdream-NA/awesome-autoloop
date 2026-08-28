#!/usr/bin/env node
import { readFileSync, existsSync } from 'node:fs';
import { projectPaths } from './lib/is-autoloop-lead.mjs';

const allow = () => { process.stdout.write('{}'); process.exit(0); };
const deny = (reason) => {
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: reason },
  }));
  process.exit(0);
};

let payload;
try { payload = JSON.parse(readFileSync(0, 'utf8') || '{}'); } catch { allow(); }
if (String(payload.tool_name || '') !== 'Agent') allow();

const ti = payload.tool_input || {};
const sub = String(ti.subagent_type || '');
if (!/^(planner|plan-reviewer|architect)$/.test(sub)) allow();

const prompt = String(ti.prompt || '');

const slug = (prompt.match(/^#\s*CARD:\s*(R-[a-z0-9-]+)/im) || [])[1];
if (!slug) allow();

if (/#\s*RUNBOOK-INSUFFICIENT:\s*\S/i.test(prompt)) allow();

const BOARD = process.env.AAL_BACKLOG || projectPaths()?.board || '';
const RUNBOOK_DIR = projectPaths()?.runbooks || '';
let board = '';
try { board = readFileSync(BOARD, 'utf8'); } catch { allow(); }

const block = board.split(/\n(?=### )/).find((b) => {
  const head = b.split('\n')[0] || '';
  return /^###\s+\[/.test(head) && new RegExp(`\\]\\s*(?:PR\\s*#\\d+\\s*·\\s*)?${slug}(?:\\s|·)`).test(head);
});
if (!block) allow();

const fixLine = (block.match(/^-\s*fix\s*:[^\n]*/m) || [])[0] || '';
if (!fixLine) allow();

const cited = [...new Set((fixLine.match(/[a-z0-9][a-z0-9._-]*\.md/gi) || []))]
  .filter((f) => existsSync(`${RUNBOOK_DIR}/${f}`));
if (!cited.length) allow();

const RUN_VERB = /(?:follow|per|run|execute|do)\s*[^\n]{0,24}(?:Phase|§|step)|(?:Phase\s*[AB]\b)/i;
if (!RUN_VERB.test(fixLine)) allow();

deny(
  `BLOCKED: this is not a wave — its fix is RUNNING SOMETHING THAT IS ALREADY WRITTEN\n\n`
  + `  card: ${slug}\n`
  + `  about to dispatch: ${sub}\n`
  + `  \`- fix:\` names an existing runbook: ${cited.map((f) => `\`docs/runbooks/${f}\``).join(' · ')}\n\n`
  + `FIX, by the situation:\n`
  + `  · the lead owns it ⇒ read that runbook and EXECUTE IT NOW; do not dispatch anyone\n`
  + `  · it needs the user (a root session, a console, credentials you cannot hold) ⇒ call AskUserQuestion this turn and write\n`
  + `    \`blocked-by=user · asked-at=<ISO Z>\` on the card header — that is not a reason to open a wave\n`
  + `  · the runbook genuinely does not cover it (a missing step, it has gone stale, it needs a new irreversible change) ⇒ write one line in the brief:\n`
  + `    \`# RUNBOOK-INSUFFICIENT: <which section falls short, and why>\` — and read that section before writing it`
);

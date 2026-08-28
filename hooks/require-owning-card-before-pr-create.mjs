#!/usr/bin/env node

import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { cardBlockForBranch, ROLE_PREFIXES } from './lib/backlog-pilot-core.mjs';
import { autoLogOnDeny } from './lib/log-denial.mjs';
import { projectPaths } from './lib/is-autoloop-lead.mjs';
autoLogOnDeny('require-owning-card-before-pr-create');

const allow = () => { process.stdout.write('{}'); process.exit(0); };
const deny = (reason) => {
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: reason },
  }));
  process.exit(0);
};

let input;
try { input = JSON.parse(readFileSync(0, 'utf8')); } catch { allow(); }
if (!input || input.tool_name !== 'Bash') allow();

const cmd = String((input.tool_input && input.tool_input.command) || '');
if (!/(^|[;&|]\s*|\s)gh\s+pr\s+create\b/.test(cmd)) allow();

const REPO_DIR = projectPaths()?.repo || '';
let branch = '';
try {
  branch = execFileSync('git', ['-C', REPO_DIR, 'rev-parse', '--abbrev-ref', 'HEAD'],
    { encoding: 'utf8', timeout: 10000 }).trim();
} catch { allow(); }
if (!branch || branch === 'HEAD') allow();

const m = /--head[= ]+(\S+)/.exec(cmd);
if (m) branch = m[1].replace(/^["']|["']$/g, '');

if (/dependabot|renovate/i.test(branch)) allow();

let board = '';
try { board = readFileSync(process.env.AAL_BACKLOG || `${REPO_DIR}/.claude/BACKLOG.md`, 'utf8'); } catch { allow(); }
if (!board) allow();

const card = cardBlockForBranch(board, branch);

const bt = String.fromCharCode(96);
const q = (s) => bt + s + bt;

const BARE_ROLE = new RegExp(`^(?:${ROLE_PREFIXES.join('|')})$`, 'i');

const rosterEnv = process.env.AAL_ROSTER_NAMES;
let roster = [];
if (rosterEnv !== undefined) {
  roster = rosterEnv.split(',').map((s) => s.trim()).filter(Boolean);
} else {
  try {
    const { liveAgentNames } = await import('./lib/roster-live-agents.mjs');
    roster = liveAgentNames(input.session_id || process.env.CLAUDE_CODE_SESSION_ID || '') || [];
  } catch { roster = []; }
}
const holders = roster.filter((n) => n && n !== 'team-lead');
if (card && holders.length) {
  const aliasLine = (card.match(/^-\s*aliases\s*:\s*(.+)$/im) || [])[1] || '';
  const tokens = new Set();
  for (const part of `${branch} ${aliasLine}`.split(/[\s,/]+/)) {
    const t = part.replace(/^["']|["'.]$/g, '').toLowerCase();
    if (t.length >= 5) tokens.add(t);
    for (const seg of t.split('-')) if (seg.length >= 5 && !BARE_ROLE.test(seg)) tokens.add(seg);
  }
  const stillHolding = holders.filter((n) => {
    const low = n.toLowerCase();
    for (const t of tokens) if (low.includes(t)) return true;
    return false;
  });
  if (stillHolding.length) {
    deny(
      `BLOCKED: the agent that delivered this is still on the roster, so this PR cannot be opened yet\n\n` +
      `  branch: ${q(branch)}\n` +
      `  still on the roster: ${stillHolding.map(q).join(' · ')}\n\n` +
      `Opening a PR is a **scope freeze**; that agent still being on the roster means this baton has not handed over. Freezing before\n` +
      `the hand-over is backwards — when you later want to add work to this PR the tree will be dirty, the SHA will be void, and the\n` +
      `worktree will be occupied, and you will have created all three of those states yourself.\n\n` +
      `FIX, in order, skipping nothing:\n` +
      `  1. collect the hand-off and ask of each item: is this **finished**, or is it **waiting on my ruling**?\n` +
      `  2. rule on everything waiting **in that same turn** — if the ruling leaves the work with that agent, do not shut it down; let it finish and come back;\n` +
      `  3. ${q('SendMessage')} a ${q('shutdown_request')} and **confirm it has left the roster** (having sent one does not count);\n` +
      `  4. only then push, open the PR, and dispatch a FRESH reviewer.\n\n` +
      `NOTE: a revision round happens INSIDE review — open the PR, get a verdict, then rework.`,
    );
  }
}

if (card) allow();

deny(
  `BLOCKED: no owning card on the board resolves to this branch, so no PR\n\n` +
  `branch: ${q(branch)} -> ${q('cardBlockForBranch')} resolved to **null**\n\n` +
  `FIX, one of two, each a single write:\n` +
  `  1. file the card first, with ${q('PR #<N>')} ownership on its header (the PR number only exists after opening ⇒ file the card, open, then add the number)\n` +
  `  2. add the **branch name, verbatim** to the ${q('- aliases:')} line of the card that already owns this work\n` +
  `     NOTE: an aliases line usually holds symptom phrases, while ${q('cardBlockForBranch')} compares BRANCH NAMES — you need both kinds on it.`,
);

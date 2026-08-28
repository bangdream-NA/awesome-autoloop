#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import { autoLogOnDeny } from './lib/log-denial.mjs';
autoLogOnDeny('block-agent-role-boundary-violation');

function read(fd) { try { return readFileSync(fd, 'utf8'); } catch { return ''; } }
let payload = {};
try { payload = JSON.parse(read(0) || '{}'); } catch { process.exit(0); }
if ((payload.tool_name || '') !== 'Agent') process.exit(0);

const ti = payload.tool_input || {};
const role = String(ti.subagent_type || '').toLowerCase();
const prompt = String(ti.prompt || '');

function deny(msg) {
  console.log(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason: msg,
    },
  }));
  process.exit(0);
}

const ARCH_VERDICT_PATH = /[\w.\/-]*planrev[-_]arch[-_]r\d+\.md/i;
const ARCH_REVIEWED_FIELD = /["']reviewed["']\s*:\s*["']\s*architect(ure)?\b/i;

if (role === 'plan-reviewer') {
  const hitPath = ARCH_VERDICT_PATH.test(prompt);
  const hitField = ARCH_REVIEWED_FIELD.test(prompt);
  if (hitPath || hitField) {
    deny(
      'BLOCKED: a plan-reviewer can only review PLAN documents, and this brief asks it to produce an ARCHITECTURE review artifact\n' +
      `  matched: ${[hitPath && 'a `…-planrev-arch-rN.md` verdict path', hitField && 'a `"reviewed": "architecture…"` ledger field'].filter(Boolean).join(' + ')}\n\n` +
      'The pipeline is: planner -> plan-review -> architect -> developer -> code-review. There is no architecture-review step.\n\n' +
      'FIX: dispatch a `developer` for this wave.\n' +
      'If you really do want a PLAN document reviewed ⇒ make the PLAN the SUBJECT (not an input), land the verdict at `…-planrev-r<N>.md`,\n' +
      'and write the field as `"reviewed": "PLAN doc r<N>"`.'
    );
  }
}

const AUTHOR_PLAN = /docs\/product-specs\/[\w.-]*-plan\.md[^\n]{0,80}(author|deliver|produce|write)/i;
if (role === 'architect' && /(?:you deliver|deliver|produce)[^\n]{0,40}-plan\.md/i.test(prompt)) {
  deny(
    'ROLE-BOUNDARY GATE — an architect authors `-architecture.md`, never `-plan.md`.\n' +
    'Dispatch a `planner` for a plan revision round.'
  );
}
if (role === 'planner' && /(?:you deliver|deliver|produce)[^\n]{0,40}-architecture\.md/i.test(prompt)) {
  deny(
    'ROLE-BOUNDARY GATE — a planner authors `-plan.md`, never `-architecture.md`.\n' +
    'Dispatch an `architect` once the plan chain is APPROVED.'
  );
}

process.exit(0);

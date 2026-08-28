#!/usr/bin/env node
import { readFileSync, existsSync, readdirSync } from 'node:fs';
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
if (String(payload.tool_name || '') !== 'AskUserQuestion') allow();

const ti = payload.tool_input || {};
const questions = Array.isArray(ti.questions) ? ti.questions : [];
if (!questions.length) allow();

const optionTexts = [];
for (const q of questions) {
  for (const o of (q.options || [])) {
    optionTexts.push(`${o.label || ''} ${o.description || ''}`);
  }
}
if (!optionTexts.length) allow();

const PERM_NOUN = '(?:root|sudo|sudoers|allowlist|permission|access|route|installer|ssh ?key|private key|credential|NOPASSWD)';
const RECIPIENT = '(?:me|us|deploy|lead|agent|the agent)';
const GIVE_VERB = '(?:grant|give|add|issue|provision|hand|open up|apply for|set up)';
const ARM_TO_ME = new RegExp(
  `${GIVE_VERB}[^\\n]{0,8}${RECIPIENT}[^\\n]{0,24}${PERM_NOUN}`
  + `|${RECIPIENT}[^\\n]{0,10}${GIVE_VERB}[^\\n]{0,16}${PERM_NOUN}`, 'i');
const WIDEN_VERB = '(?:restore|widen|loosen|relax|re-?enable|whitelist|exempt|lift|un-?block'
  + '|add (?:it )?(?:back|to|into)|put (?:it )?back|open (?:the )?route|bring back)';
const ARM_WIDEN = new RegExp(
  `${WIDEN_VERB}[^\\n]{0,24}${PERM_NOUN}`
  + `|${PERM_NOUN}[^\\n]{0,20}(?:restore|widen|loosen|relax|add back|put back)`
  + `|grant[^\\n]{0,24}${PERM_NOUN}`, 'i');

const offending = optionTexts.filter((t) => ARM_TO_ME.test(t) || ARM_WIDEN.test(t));
if (!offending.length) allow();

const whole = JSON.stringify(ti);
const CHECKED_RE = /#?\s*LOCKED-DECISION-CHECKED:\s*([^\s"]+\.(?:md|ya?ml|ts|mjs|sh|json):\d+|[^\s"]+\.md|none\b)/i;
const SINCE_RE = /SINCE-LOCK-CHANGED:\s*([^\n"]{8,})/i;
const checked = whole.match(CHECKED_RE);
if (checked) {
  const cite = checked[1];
  if (/^none$/i.test(cite)) allow();
  const p = projectPaths();
  const rel = cite.split(':')[0];
  const base = rel.split('/').pop();
  const cands = p ? [`${p.repo}/${rel}`, `${p.specs}/${base}`, `${p.runbooks}/${base}`, `${p.repo}/${base}`] : [];
  if (!cands.some((c) => existsSync(c))) {
    deny(
      `BLOCKED: the file \`LOCKED-DECISION-CHECKED:\` cites does not exist in the repo: \`${rel}\`\n\n`
      + `The ENTIRE value of that field is that someone can re-check it. Citing a path that does not exist is the same as\n`
      + `not writing the field at all — the only difference is that it reads as though the work was done.\n`
      + `Write a REPO-RELATIVE path (for example \`deploy/alertmanager/alertmanager.yml:39\`), or a bare filename under specs/runbooks.`,
    );
  }
  if (SINCE_RE.test(whole)) allow();
  deny(
    `BLOCKED: a locked decision is cited, but nothing says **what has changed since that lock**\n\n`
    + `  You cited: \`${cite}\`\n\n`
    + `**The way out**: add one more line inside the same option\n`
    + `    \`SINCE-LOCK-CHANGED: <what changed after that lock, such that it no longer covers this>\`\n`
    + `If you cannot name a change, do not ask them — carry out the lock.`,
  );
}

const dir = projectPaths()?.specs || '';
let hint = '';
try {
  const fam = readdirSync(dir).filter((f) => /sudo|allowlist|root|escalat|privilege|identity/i.test(f));
  if (fam.length) hint = `\n  The answer may be inside this family (${fam.length} document(s)):\n    `
    + fam.slice(0, 6).map((f) => `\`${f}\``).join('\n    ')
    + (fam.length > 6 ? `\n    …and ${fam.length - 6} more` : '');
} catch {  }

deny(
  `BLOCKED: an option proposes RELAXING A LIMIT without showing that the wave which created it is absent\n\n`
  + `  Matching option(s), first 2:\n`
  + offending.slice(0, 2).map((t) => `    "${t.slice(0, 90)}"`).join('\n') + '\n'
  + `${hint}\n\n`
  + `FIX. After searching, write one line inside any option's description:\n`
  + `    \`LOCKED-DECISION-CHECKED: <spec filename>.md:<line>\` (cite the line you actually read)\n`
  + `Genuinely nobody ever ruled on it ⇒ \`LOCKED-DECISION-CHECKED: none\`.\n`
  + `NOTE: it is an assertion, not an incantation — read that section before writing it.`,
);

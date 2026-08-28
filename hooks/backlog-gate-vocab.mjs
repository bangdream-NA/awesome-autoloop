#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import { blockedByTokens, GATE_TOKEN_RE, GATE_TOKEN_HELP, LEGACY_GATE_TOKEN_RE, hasAskedAt, statusOf, OPEN_STATUSES } from './lib/backlog-gate.mjs';
import { logDenial } from './lib/log-denial.mjs';

const ACCEPTED = GATE_TOKEN_HELP;

function allow() { process.stdout.write('{}'); process.exit(0); }
function deny(reason) {
  logDenial('backlog-gate-vocab', null, reason);
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: reason },
  }));
  process.exit(0);
}

let payload = {};
try { payload = JSON.parse(readFileSync(0, 'utf8') || '{}'); } catch { allow(); }

const tool = String(payload.tool_name || '');
if (!['Write', 'Edit', 'MultiEdit'].includes(tool)) allow();

const ti = payload.tool_input || {};
const file = String(ti.file_path || '').replace(/\\/g, '/');
if (!/\/\.claude\/BACKLOG[^/]*\.md$/i.test(file)) allow();

let introduced = '';
if (tool === 'Write') introduced = String(ti.content || '');
else if (tool === 'Edit') introduced = String(ti.new_string || '');
else if (tool === 'MultiEdit') introduced = (ti.edits || []).map((e) => String(e.new_string || '')).join('\n');
if (!introduced.trim()) allow();

const bad = [];
const empty = [];
const unasked = [];
const contradiction = [];
const TERMINAL_DOD_RE = /DoD-VERIFIED|dod-verified-at=|DoD-OBSOLETE|obsolete-at=/;
const noArtifact = [];
for (const line of introduced.split(/\r?\n/)) {
  if (!/^### \[/.test(line)) continue;
  const tokens = blockedByTokens(line);
  const name = (line.match(/R-[a-z0-9-]+/i) || ['(card)'])[0];
  for (const t of tokens) if (!GATE_TOKEN_RE.test(t)) bad.push(`${name} → blocked-by=${t}`);
  if (tokens.includes('user') && !hasAskedAt(line)) unasked.push(name);
  if (tokens.length && TERMINAL_DOD_RE.test(line)) {
    contradiction.push(`${name} → blocked-by=${tokens.join(',')} + ${(line.match(TERMINAL_DOD_RE) || [''])[0]}`);
  }
  const lineSansGates = line.replace(/blocked-by=\S+/gi, '');
  if (tokens.some((t) => /^merge-order:pr#/i.test(t))
      && /\bstage=new\b/i.test(line)
      && !/\bPR\s#\d+/.test(lineSansGates)) {
    noArtifact.push(name);
  }
  if (!tokens.length && /\[\s*gate\s*[=:]/i.test(line) && OPEN_STATUSES.includes(statusOf(line))) {
    empty.push(name);
  }
}

const CARD_SLUG_RE = /R-[a-z0-9]+(?:-[a-z0-9]+){2,}/i;
const GATE_DECL_RE = /DoD-GATED\s*:|observe-until\s+\d{4}-\d{2}-\d{2}/i;

const GRANT_NOUN = '(?:token|credential|secret|api[- ]?key|approval|permission|authorisation|sign-?off)';
const HUMAN_GRANT_RE = new RegExp(
  `(?:only|still|awaiting|pending|waiting on|blocked on|missing|needs?|requires?)[^·\\n]{0,24}${GRANT_NOUN}`
  + `|${GRANT_NOUN}[^·\\n]{0,24}(?:is|are)\\s+(?:missing|pending|outstanding|needed|required|not\\s+(?:yet\\s+)?(?:granted|available))`,
  'i');

const EXECUTOR_US_RE = new RegExp(
  '(?:executor|owner)\\s*(?:is|=|:)?\\s*(?:lead|me|myself)'
  + '|(?:falls|belongs|down)\\s+to\\s+(?:lead|me)'
  + '|(?:by|for)\\s+(?:me|lead)\\s+to\\s+(?:do|run|walk|verify|measure|execute|complete)'
  // Both apostrophes, and NO bare `ll` alternative: with `ll` the pattern matched inside
  // `still <verb> it`, so `still run it` read as an executor claim. See the R7/G7 pair in
  // hooks/tests/backlog-gate-vocab-widening.test.sh.
  + '|I(?:\\s+will|[\\u0027\\u2019]ll)?\\s+(?:do|run|walk|finish|handle)\\s+(?:it|this|them)',
  'i');
const EXEC_ALREADY_RE = /\b(?:already|done|completed|finished|ran|first-hand)\b/i;
const RAN_REAL_RE = /ran\s*=\s*(?:20\d\d|auto@|\d{6,})/i;
function executorIsUsHit(decl) {
  const m = String(decl).match(EXECUTOR_US_RE);
  if (!m) return null;
  const at = m.index;
  const clause = decl.slice(0, at).split(/[·,;\n]/).pop() || '';
  if (EXEC_ALREADY_RE.test(clause)) return null;
  if (RAN_REAL_RE.test(decl.slice(at, at + 40))) return null;
  return m[0];
}

const EXECUTOR_NOUN_RE = /\bconsole\b|\bby hand\b|\bmanually\b|\bin person\b|\bthe user\b/gi;
const OUTSTANDING_RE = /\b(?:only|still|just)?\s*(?:needs?|requires?|lacks?|missing|outstanding|remaining|left)\b/i;
const ALREADY_RE = /\b(?:already|done|completed|ran|installed|executed)\b/i;
function humanExecutorHit(decl) {
  for (const nm of String(decl).matchAll(EXECUTOR_NOUN_RE)) {
    const at = nm.index;
    if (ALREADY_RE.test(decl.slice(Math.max(0, at - 6), at))) continue;
    const win = decl.slice(Math.max(0, at - 60), at);
    const seg = win.slice(win.lastIndexOf('·') + 1);
    const om = seg.match(OUTSTANDING_RE);
    if (om) return `${om[0]}…${nm[0]}`;
  }
  return null;
}

const TRIGGERABLE_RE = /\b(?:pipeline|orchestrator|republish|publish|ingest|cron|timer|ci|workflow|dispatch|scheduled|rerun)\b/i;
const TRIGGER_CHECKED_RE = /manual-trigger-checked=/i;

const GATE_TAIL_RE = /DoD-GATED\s*:\s*observe-until\s+\d{4}-\d{2}-\d{2}/i;
const MIN_GATE_EXPLANATION = 12;
const PRE_WAIT_WALK_RE = /pre-wait-walk=/i;
const unwalkedGates = [];

const fakeGates = [];
const humanGrantGates = [];
const humanExecutorGates = [];
const ourOwnWorkGates = [];
const triggerables = [];
for (const line of introduced.split(/\r?\n/)) {
  if (!GATE_DECL_RE.test(line)) continue;
  const at = line.search(GATE_DECL_RE);
  const decl = line.slice(at);
  const stripped = decl.replace(/merge-order:wave:R-[a-z0-9-]+/gi, '');
  const m = stripped.match(CARD_SLUG_RE);
  if (m) fakeGates.push(m[0]);
  const hg = stripped.match(HUMAN_GRANT_RE);
  if (hg) humanGrantGates.push(hg[0]);
  const he = humanExecutorHit(stripped);
  if (he) humanExecutorGates.push(he);
  const eu = executorIsUsHit(stripped);
  if (eu) ourOwnWorkGates.push(eu);
  const tg = decl.match(TRIGGERABLE_RE);
  if (tg && !TRIGGER_CHECKED_RE.test(line)) triggerables.push(tg[0].toLowerCase());
  const gm = line.match(GATE_TAIL_RE);
  if (gm && !PRE_WAIT_WALK_RE.test(line)) {
    const after = line.slice(gm.index + gm[0].length);
    const segs = after.split(' · ').map((x) => x.replace(/^[\s\u2014\-\u2013:]+/, '').trim()).filter(Boolean);
    const first = segs[0] || '';
    const NOISE = /^(?:\*{0,2}[\p{L}\w-]+\*{0,2}=)|^(?:[🔴🟠🟡🔵⏳✅⚠️]|\*{0,2}P[0-3]\b|\[[A-Z-]+\]|MERGED\b|PR\s*#\d)/u;
    const clean = first.replace(/[*`\s]/g, '');
    if (NOISE.test(first) || clean.length < MIN_GATE_EXPLANATION) {
      unwalkedGates.push(`${gm[0]} (immediately followed by "${first.slice(0, 28) || '(nothing)'}")`);
    }
  }
}

if (unwalkedGates.length) {
  deny(
    `BLOCKED: a bare observe-until — it does not say WHAT IS ALREADY DONE or WHAT IS LEFT TO WAIT FOR: ${[...new Set(unwalkedGates)].join(' · ')}\n\n` +
    `FIX, one of three:\n` +
    `  1. add after the gate: \"X is verified first-hand; only Y is left, and the passage of time alone clears it\"\n` +
    `  2. it really is finished => \`DoD-VERIFIED\` and move the whole card to the archive\n` +
    `  3. \`pre-wait-walk=<the command you ran and what you saw>\` — a reading, not an assertion that you verified something\n` +
    `Fewer than about a dozen words of explanation triggers this.`,
  );
}

if (noArtifact.length) {
  deny(
    `BLOCKED: \`merge-order:\` on a card with no artifact: ${[...new Set(noArtifact)].join(' · ')}\n\n` +
    `FIX: name the SPECIFIC FILE both sides change. If you cannot name one, delete the gate and leave the card in \`[QUEUED]\` — do not change the badge.`,
  );
}

if (fakeGates.length) {
  deny(
    `BLOCKED: an observe-until line that NAMES A CARD is waiting on work, not on time: ${[...new Set(fakeGates)].join(' · ')}\n\n` +
    `FIX — pick by the facts:\n` +
    `  a PR is open       => \`blocked-by=merge-order:pr#<N>\`\n` +
    `  a wave has a card  => \`blocked-by=merge-order:wave:<R-slug>\`\n` +
    `  neither            => write no gate and leave the card open\n` +
    `A pure time window that names no card is still fine.`,
  );
}

if (humanGrantGates.length) {
  deny(
    `BLOCKED: this gate is waiting on SOMETHING A PERSON MUST GIVE YOU, and a calendar does not clear it: ${[...new Set(humanGrantGates)].join(' · ')}\n\n` +
    `FIX: \`blocked-by=user\` + \`asked-at=<ISO Z>\`, and ask them in this same turn.\n` +
    `Exemption: nothing is actually needed from anyone => rewrite what you are waiting on as the time event itself.`,
  );
}

if (triggerables.length) {
  deny(
    `BLOCKED: ${[...new Set(triggerables)].join(' · ')} has a trigger command, so this gate is waiting on whether you run it, not on time\n\n`
    + `Not run yet => run it now.\n`
    + `Run and waiting => \`manual-trigger-checked=<when you triggered it + expected duration>\`\n`
    + `Run and it did not help => \`manual-trigger-checked=<the reason you MEASURED>\` — measured, not quoted from a document.`,
  );
}

if (humanExecutorGates.length) {
  deny(
    `BLOCKED: this gate is waiting on AN ACTION A PERSON MUST TAKE, and a calendar does not clear it: ${[...new Set(humanExecutorGates)].join(' · ')}\n\n` +
    `FIX: \`[USER-GATED]\` + \`blocked-by=user\` + \`asked-at=<ISO Z>\` + a \`- user-question:\` line, and ask them in this same turn.\n` +
    `Exemption 1: the action is actually yours => do it now, and write no gate.\n` +
    `Exemption 2: nobody ever approved the action that would make that arm green => retire the arm and settle it as DoD-VERIFIED or DoD-FAILED.`,
  );
}

if (ourOwnWorkGates.length) {
  deny(
    `BLOCKED: this gate names YOU as the executor, so it is waiting on your own work and no calendar clears it: ${[...new Set(ourOwnWorkGates)].join(' · ')}\n\n` +
    `FIX, two routes — pick by the facts:\n` +
    `  1. do those items now; when they are done write \`DoD-VERIFIED\` and move the whole card to the archive (if it is a few commands, take this route)\n` +
    `  2. another baton's work really is in the way => \`blocked-by=merge-order:pr#<N>\` or \`merge-order:wave:<R-slug>\`\n` +
    `Exemption: that work is ALREADY done and only a timer remains => put the executor sentence in the past tense and name the time event you are still waiting on.`,
  );
}

if (contradiction.length) {
  deny(
    `BLOCKED: a card cannot be BLOCKED and ACCEPTED at the same time: ${contradiction.join(' · ')}\n\n` +
    `Pick one:\n` +
    `  the gate still holds => delete the terminal token (DoD-VERIFIED / dod-verified-at= / DoD-OBSOLETE / obsolete-at=).\n` +
    `  the gate is cleared  => delete blocked-by=, move the whole card into the archive file, and set the status badge to [DONE].\n\n` +
    `DoD-FAILED + dod-failed-at=, and DoD-GATED: observe-until <date>, are NOT in this class — they may coexist with a gate.`);
}

if (unasked.length) {
  deny(
    `BLOCKED: \`blocked-by=user\` with no \`asked-at=\`: ${unasked.join(' · ')}\n\n` +
    `FIX. Write it only in the turn you actually asked: \`· blocked-by=user · asked-at=<ISO Z from date -u> ·\`\n` +
    `Not asked yet => delete \`blocked-by=user\` and leave the card open. If they are present, ask now.`);
}

if (bad.length) {
  const legacy = bad.filter((b) => LEGACY_GATE_TOKEN_RE.test(b.split('blocked-by=')[1] || ''));
  deny(
    `BLOCKED: illegal gate token: ${bad.slice(0, 5).join(' · ')}` +
    (legacy.length ? ` (${legacy.length} of them are retired vocabulary)` : '') + `\n\n` +
    `FIX. The only legal form, verbatim: \`· blocked-by=${ACCEPTED} ·\`\n` +
    `Test to apply first: before the thing you are waiting on lands, can this card be FINISHED AND MERGED? If yes, do not write a gate — queue it by priority.\n` +
    `Merely explaining a token rather than asserting one => put it in backticks.`);
}

if (empty.length) {
  deny(
    `BLOCKED: a \`[gate = ...]\` bracket with no \`· blocked-by=<token> ·\` field inside it: ${empty.slice(0, 5).join(' · ')}\n\n` +
    `Accepted tokens, verbatim: ${ACCEPTED}\n` +
    `FIX, one of three:\n` +
    `  (a) genuinely blocked  => write \`· blocked-by=<token> ·\` INSIDE the bracket; prose goes after it\n` +
    `  (b) recording a release => do not use a bracket at all; write it as prose outside one (\`original blocked-by=pr#984 is cleared\`)\n` +
    `  (c) not blocked        => delete the bracket and leave the card open`);
}

allow();

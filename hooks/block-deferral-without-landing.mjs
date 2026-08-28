#!/usr/bin/env node

import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { lastAssistantText, stripQuoted } from './lib/transcript-last-assistant.mjs';
import { hasLanded } from './lib/landed-evidence.mjs';
import { autoLogOnDeny } from './lib/log-denial.mjs';
import { projectPaths } from './lib/is-autoloop-lead.mjs';
autoLogOnDeny('block-deferral-without-landing');

const allow = () => { process.stdout.write('{}'); process.exit(0); };

let input;
try { input = JSON.parse(readFileSync(0, 'utf8')); } catch { allow(); }

const lastText = lastAssistantText(input);
if (!lastText) allow();

// Every phrase list below is matched on WORD BOUNDARIES, never by substring containment.
// Containment is what the original could afford, because the language it scanned has no word
// delimiter; in English `later` sits inside `laterally` and `on me` inside `on merge`, so
// boundaries are not a refinement here, they are the only correct port.
const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const phraseRe = (s) => new RegExp(`\\b${esc(s).replace(/\s+/g, '\\s+')}\\b`, 'i');
const anyPhrase = (list) => {
  const compiled = list.map((p) => [p, phraseRe(p)]);
  return (s) => (compiled.find(([, re]) => re.test(s)) || [])[0];
};

const DEFER = [
  'next turn I', 'in the next message', 'next round I', 'after that I',
  'when you have time', 'when they have time', 'no rush',
  'not doing this for now', 'leave it for now', 'park it for now',
  'later on I', 'come back to it',
  'deserves a card', 'should be a card', 'worth a card of its own', 'wants a card of its own',
  'next turn', 'later this session', 'will do next',
];
const deferHit = anyPhrase(DEFER);

const LANDING = /\bR-[a-z0-9][a-z0-9-]{4,}|(?:PR\s*)?#\d{2,5}\b|20\d\d-\d\d-\d\d|\b[Bb]atch\s*\d+\b/;
const EXEC_ANCHOR_ACT = 'shut\\s*down|push|open\\s*(?:a\\s*)?PR|file\\s*(?:a\\s*)?card|dispatch'
  + '|land|archive|merge|re-?check|walk|rule|wrap\\s*up|clean\\s*up|reconcile'
  + '|re-?run|re-?dispatch|re-?verify';
const EXECUTOR_ANCHOR_RE = new RegExp(
  `\\b(?:waiting\\s+(?:for|on)|wait\\s+for)\\s+(?:me|you|the\\s+user)\\s+to\\s+(?:${EXEC_ANCHOR_ACT})`
  + '(?!\\s+(?:this|that)\\s+(?:one|thing|item|matter|step)\\b)', 'i');

const OWNED_VERB = 'archive|dispatch|push|file|fix|change|merge|write|run|delete|remove'
  + '|clean\\s*up|re-?check|re-?measure|verify|deploy|publish|handle|check|backfill|take|do';
const SUBJECTLESS_NEXT_RE = new RegExp(
  `\\bnext\\s+step\\s+(?:is|will\\s+be)\\s+(?:to\\s+)?(?:${OWNED_VERB})\\b`, 'i');

const SOON_PREFIX = 'next\\s+step|next\\s+round|next\\s+turn|after\\s+that|afterwards'
  + '|shortly|later\\s+on|in\\s+a\\s+bit|once\\s+that\\s+is\\s+done';
// The window is 12 characters where the original used 8: the original counted CJK characters,
// which are roughly one word each, so a same-length window in English would not reach the verb.
// 12 is the smallest window that still reaches it in `next step, then run the sweep`.
const NEXT_THEN_VERB_RE = new RegExp(
  `(?:${SOON_PREFIX})[^.;!?\\n]{0,12}?\\b(?:${OWNED_VERB})\\b`, 'i');
const OTHER_ACTOR_RE =
  /\b(?:handled|done|owned|run|driven)\s+by\s+(?:the\s+)?(?:reviewer|CI|pipeline|cron|orchestrator|someone\s+else)\b|\bautomatically\b|\bnot\s+mine\b|\bnot\s+my\s+(?:job|call|baton|work)\b|\breviewer\b|\bCI\s+(?:will|automatically)\b/i;
const DEBT_ARTIFACT = 'must-red control|must-red|must-green|fixture|arm|card|doc|runbook'
  + '|log|ledger|PR|screenshot|walk|archive|test';
const QUANT = '(?:(?:a|one|two|three|four|five|six|seven|eight|nine|ten|several|\\d+)\\s+)?';
const BARE_DEBT_RE = new RegExp(
  `\\b(?:still\\s+owes?|owes?|still\\s+missing|still\\s+short\\s+of|short\\s+by)\\s+${QUANT}(?:${DEBT_ARTIFACT})\\b`
  + `|\\b(?:not|none)\\s+(?:a\\s+single\\s+)?[^.;!?\\n]{0,14}?(?:${DEBT_ARTIFACT})[^.;!?\\n]{0,10}?\\b(?:yet|at\\s+all)\\b`
  + '|\\ball\\s+of\\s+it\\s+is\\s+manual\\b|\\bentirely\\s+manual\\b|\\bonly\\s+did\\s+it\\s+manually\\b',
  'i');
// Quoting one of the trigger phrases in order to talk ABOUT it is not a promise.
const QUOTING_RE =
  /["“‘][^"”’]{0,60}(?:still owes?|none of them|all manual)|\bthat sentence\b|\bprecisely\b|\bthe gate should catch\b|\bfalse positive\b|\bthe measured corpus\b/i;

const NEXT_NOUN_IS_PRONOUN_RE =
  /\bthe\s+next\s+(?:message|one|item|step|card|baton|round)[^.;!?\n]{0,10}\bis\s+(?:them|it|these|those|this|that|the\s+above|the\s+ones\s+above)\b/i;
const SOON_BARE_RE = /\bnext\s+round\b|\bshortly\b|\blater\s+on\b/i;
const NOT_A_COMMITMENT_RE =
  /\bnext\s+round(?:'s|s')\b|\botherwise\b|\bin\s+case\b|\bif\b|\bonce\b|\bshould\s+it\b|\bprecisely\b|\bthe\s+discriminator\s+is\b|\bthe\s+test\s+is\b/i;
const SLUG_RE = /\bR-[a-z0-9][a-z0-9-]{4,}/g;

// projectPaths() resolves the board directory out of the transcript, NOT out of
// CLAUDE_PROJECT_DIR. AAL_DEFERRAL_BOARD_DIR is the only override this gate honours; fixtures
// point it at a scratch board so the arms do not depend on whatever board is live.
const LANDING_FRESH_MS = 15 * 60 * 1000;
const LOG_TS_RE = /^-\s*log:\s*(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)/gm;
const cardNewestLog = (() => {
  const map = new Map();
  try {
    const dir = process.env.AAL_DEFERRAL_BOARD_DIR || projectPaths(input)?.claude || '';
    for (const f of readdirSync(dir)) {
      if (!/^BACKLOG.*\.md$/i.test(f) || /\.bak/i.test(f)) continue;
      for (const chunk of readFileSync(join(dir, f), 'utf8').split('\n### ')) {
        const m = /^\[[A-Z-]+\]\s+(R-[a-z0-9][a-z0-9-]+)/i.exec(chunk.split('\n')[0]);
        if (!m) continue;
        const stamps = [...chunk.matchAll(LOG_TS_RE)]
          .map((x) => Date.parse(x[1])).filter((n) => Number.isFinite(n));
        map.set(m[1].toLowerCase(), stamps.length ? Math.max(...stamps) : null);
      }
    }
  } catch {  }
  return map;
})();
const CONSIGN_VERB = 'archived\\s+(?:it\\s+)?(?:to|into|under|on)|filed\\s+(?:it\\s+)?(?:as|under|on)'
  + '|opened|created|recorded\\s+(?:it\\s+)?(?:on|in|under)|written\\s+(?:it\\s+)?(?:to|into)'
  + '|logged\\s+(?:it\\s+)?(?:on|under)|moved\\s+(?:it\\s+)?(?:to|into)|landed\\s+(?:it\\s+)?(?:on|in)';
const CONSIGNED_SLUG_RE = new RegExp(`(?:${CONSIGN_VERB})\\s*:?\\s*\`?(R-[a-z0-9][a-z0-9-]{4,})`, 'gi');
const landingResolves = (s) => {
  if (!LANDING.test(s)) return false;
  const slugs = s.match(SLUG_RE) || [];
  if (!slugs.length) return true;
  if (cardNewestLog.size === 0) return true;
  const now = Date.now();
  const consigned = new Set([...s.matchAll(CONSIGNED_SLUG_RE)].map((m) => m[1].toLowerCase()));
  return slugs.some((g) => {
    const key = g.toLowerCase().replace(/[^a-z0-9-]+$/, '');
    if (!cardNewestLog.has(key)) return false;
    if (consigned.has(key)) return true;
    const ts = cardNewestLog.get(key);
    if (ts === null) return true;
    return now - ts <= LANDING_FRESH_MS;
  });
};

const units = (() => {
  const TERM = /[!?\n]+|(?<=[.!?])\s+/g;
  const out = []; let last = 0; let m;
  while ((m = TERM.exec(lastText))) {
    out.push({ raw: lastText.slice(last, m.index), term: m[0] });
    last = m.index + m[0].length;
  }
  if (last < lastText.length) out.push({ raw: lastText.slice(last), term: '' });
  return out.map((p) => ({ s: p.raw.trim(), q: /\?/.test(p.term) }))
    .filter((p) => p.s);
})();
const offenders = [];
const stripCode = stripQuoted;

const UNDONE = [
  'not dispatched yet', 'has not been dispatched', 'still unstaffed', 'still short of hands',
  'nobody has picked it up', 'nobody has taken it', 'unclaimed',
  'zero verdicts', '0 verdicts', 'still red', 'still failing',
  'not walked yet', 'has not been walked', 'not built yet', 'not created yet',
  'not done yet', 'not pushed yet', 'not backfilled yet', 'not finished', 'not yet finished',
];
const undoneListHit = anyPhrase(UNDONE);
const UNDONE_TAIL_RE =
  /\b(?:not|never)\s+(?:yet\s+)?(?:fully\s+)?(?:backfilled|done|run|written|changed|fixed|built|dispatched|pushed|verified|tested|swept)\b/i;
// `pending` / `to be <verb>ed` is a report of undone work — EXCEPT when what is pending is the
// user's own ruling, which is the one wait this gate has never owned.
const UNDONE_RE =
  /\b(?:yet\s+to\s+be|still\s+to\s+be|to\s+be)\s+(?!ruled|answered|approved|signed|decided|confirmed)\w+ed\b|\bpending\s+(?!a\s+ruling|the\s+user|approval|sign-?off|a\s+reply|an\s+answer)\w+/i;
const RESIDUAL_RE =
  /\b(?:still|there\s+(?:are|is)|that\s+leaves|leaving)\s+(?:a|one|two|three|four|five|six|seven|eight|nine|ten|\d+)\s+(?:more\s+)?(?:items?|cards?|batons?|files?|steps?|arms?|fixtures?|rounds?)\b[^.;!?\n]{0,12}\b(?:left|remaining|outstanding|to\s+go|to\s+do)\b/i;
const NEXT_ROUND_RE = new RegExp(
  '\\b(?:push|punt|move|leave|save|defer|hold|carry)\\s+(?:it|this|that|them|these)?\\s*(?:over\\s+)?(?:to|for|until|into)\\s+(?:the\\s+)?next\\s+(?:round|turn|wave|session|pass)\\b'
  + '|\\bnext\\s+(?:round|turn|wave)\\b[^.;!?\\n]{0,12}?\\b(?:do|fix|dispatch|handle|run|verify|merge|file|write|change|backfill)\\b'
  + '|\\b(?:later|afterwards|when\\s+I\\s+have\\s+time|when\\s+there\\s+is\\s+time)\\b[^.;!?\\n]{0,12}?\\b(?:do|fix|dispatch|handle|run|verify|merge|file|write|change|backfill)\\b',
  'i');

for (const { s, q: isQuestion } of units) {
  const bare = stripCode(s);
  if (hasLanded(bare, true) && !EXECUTOR_ANCHOR_RE.test(bare)) continue;
  const ATTITUDE =
    /(?:reads?\s+as|reads?\s+like|looks?\s+like|sounds?\s+like|would\s+be\s+read\s+as|one\s+might\s+think|misread\s+as)[^.;]{0,16}$/i;
  const NEGATION = /\b(?:not|never|no|without|need\s+not|do\s+not|don't|nothing)\b[^.;!?\n]{0,10}$/i;
  const undoneRaw = undoneListHit(bare)
    || (UNDONE_RE.test(bare) ? (bare.match(UNDONE_RE) || [])[0] : undefined)
    || (UNDONE_TAIL_RE.test(bare) ? (bare.match(UNDONE_TAIL_RE) || [])[0] : undefined)
    || (RESIDUAL_RE.test(bare) ? (bare.match(RESIDUAL_RE) || [])[0] : undefined)
    || (NEXT_ROUND_RE.test(bare) ? (bare.match(NEXT_ROUND_RE) || [])[0] : undefined);
  const beforeUndone = undoneRaw ? bare.slice(0, bare.indexOf(undoneRaw)) : '';
  const undone = (undoneRaw && (ATTITUDE.test(beforeUndone) || NEGATION.test(beforeUndone)))
    ? undefined : undoneRaw;
  if (undone && !/^[>|]/.test(s)) {
    offenders.push({ hit: `${undone} (a status report IS a deferral; a landing does not exempt it)`, s: s.slice(0, 140) });
    continue;
  }
  const PERM_ALWAYS = ['should I', 'shall I', 'do you want me to', 'your call', 'up to you', 'whatever you prefer'];
  const PERM_IF_QUESTION = ['want me to', 'need me to', 'would you like me to', 'or do you want to', 'or should we look first'];
  const PERMISSION_SEEKING = isQuestion ? [...PERM_ALWAYS, ...PERM_IF_QUESTION] : PERM_ALWAYS;
  const ASKED = /AskUserQuestion/.test(lastText);
  const perm = ASKED ? undefined : anyPhrase(PERMISSION_SEEKING)(bare);
  if (perm && !/^[>|]/.test(s)) {
    offenders.push({ hit: `${perm}...? (your own work, dressed up as a question)`, s: s.slice(0, 140) });
    continue;
  }

  const IMMEDIACY = [
    'I will do it right now', 'doing it right now', 'right away', 'I am about to',
    'let me go and', 'I will go and', 'I will immediately', 'immediately after this',
  ];
  const imm = anyPhrase(IMMEDIACY)(bare);
  if (imm && !/^[>|]/.test(s)) {
    offenders.push({ hit: `${imm} (claims to be doing it on the spot, and this message did not; a landing does not exempt it)`, s: s.slice(0, 140) });
    continue;
  }

  const CLAIMED_NOT_DONE = [
    'that one is mine', 'mine to do', 'I will do it', 'my job', 'on me',
    'I own that', 'I own this', 'that falls to me', 'I will handle it', 'I will take it',
  ];
  const DONE_MARK = /\b(?:already|done|finished|completed|fixed|cleaned\s+up|ran|landed)\b/i;
  const claim = anyPhrase(CLAIMED_NOT_DONE)(bare);
  // OTHER_ACTOR_RE is consulted here and nowhere in the original, because two English phrases in
  // the list above survive their own negation as substrings (`my job` sits inside `not my job`).
  if (claim && !DONE_MARK.test(bare) && !OTHER_ACTOR_RE.test(bare) && !/^[>|]/.test(s)) {
    offenders.push({ hit: `${claim} (claiming it is not doing it; a landing does not exempt it, because a claim reads more responsible than a deferral)`, s: s.slice(0, 140) });
    continue;
  }

  const EVENT_ANCHOR_RE =
    /\b(?:before|after|afterwards|once\s+it\s+returns|once\s+it\s+is\s+green|after\s+the\s+merge|once\s+it\s+lands|after\s+it\s+ships|after\s+they\s+answer|once\s+approved|when\s+it\s+comes\s+back)\b/i;
  const FUTURE_ACTION_RE =
    /\b(?:do\s+it|finish\s+it|fill\s+it\s+in|wrap\s+it\s+up|run\s+it|get\s+to\s+it|start\s+on\s+it|pick\s+it\s+up|re-?dispatch|re-?verify|re-?run|ask\s+again)\b/i;
  const DEBT_THIRD_PERSON_RE =
    /\bstill\s+owes?\b|\bowed\s+by\s+(?:me|the\s+lead|lead)\b|\blead(?:'s)?\s+own\s+debt\b|\bbelongs\s+to\s+(?:me|the\s+lead|lead)\b/i;
  if (!/^[>|]/.test(s)) {
    const anchorAt = bare.search(EVENT_ANCHOR_RE);
    if (anchorAt >= 0 && FUTURE_ACTION_RE.test(bare.slice(anchorAt))) {
      offenders.push({ hit: 'event-anchored deferral (do it after X; no time word needed, and a landing does not exempt it)', s: s.slice(0, 140) });
      continue;
    }
    if (DEBT_THIRD_PERSON_RE.test(bare)) {
      offenders.push({ hit: 'third-person debt (a claim written as a classification; a landing does not exempt it)', s: s.slice(0, 140) });
      continue;
    }
    const SELF_ANCHOR_ACT = 'shut\\s*down|push|merge|open\\s*(?:a\\s*)?PR|file\\s*(?:a\\s*)?card|dispatch'
      + '|land|archive|re-?check|walk|rule|approve|verify|handle|absorb|follow\\s*up|wrap\\s*up'
      + '|clean\\s*up|update|reply|check|judge|do|change|fix|write|backfill|ask';
    const SELF_AS_ANCHOR_RE = new RegExp(
      `\\b(?:waiting\\s+(?:for|on)|wait\\s+for)\\s+me\\s+to\\s+(?:${SELF_ANCHOR_ACT})\\b`, 'i');
    if (SELF_AS_ANCHOR_RE.test(bare)) {
      offenders.push({ hit: 'YOURSELF as the anchor (waiting for me to X; neither a time nor an event, and a landing does not exempt it)', s: s.slice(0, 140) });
      continue;
    }
    const LEAD_ONLY_ACT = 'shut\\s*down|push|open\\s*(?:a\\s*)?PR|file\\s*(?:a\\s*)?card|dispatch'
      + '|land|archive|merge|re-?check|walk|rule|wrap\\s*up|clean\\s*up|reconcile'
      + '|re-?run|re-?dispatch|re-?verify';
    const SECOND_PERSON_ANCHOR_RE = new RegExp(
      `\\b(?:waiting\\s+(?:for|on)|wait\\s+for)\\s+(?:you|the\\s+user)\\s+to\\s+(?:${LEAD_ONLY_ACT})\\b`, 'i');
    if (SECOND_PERSON_ANCHOR_RE.test(bare)) {
      offenders.push({ hit: 'THEM as the anchor, on an action only the lead can take (misrouted AND deferred; a landing does not exempt it)', s: s.slice(0, 140) });
      continue;
    }
  }

  const hit = deferHit(bare)
    || (SUBJECTLESS_NEXT_RE.test(bare) && !OTHER_ACTOR_RE.test(bare) ? 'next step is (subjectless debt)' : null)
    || (NEXT_THEN_VERB_RE.test(bare) && !OTHER_ACTOR_RE.test(bare) ? 'next-step + one of our own verbs (subject omitted)' : null)
    || (SOON_BARE_RE.test(bare) && !NOT_A_COMMITMENT_RE.test(bare)
      ? 'next round / shortly (bare, and not in a descriptive form)' : null)
    || (NEXT_NOUN_IS_PRONOUN_RE.test(bare) && !OTHER_ACTOR_RE.test(bare)
      ? 'the next <noun> is <pronoun> (no verb at all; the action is pointed back at a pronoun)' : null)
    || (BARE_DEBT_RE.test(bare) && !QUOTING_RE.test(bare) && !OTHER_ACTOR_RE.test(bare)
      ? 'a debt admitted with no one named and no time named' : null);
  if (!hit) continue;
  if (landingResolves(s)) continue;
  if (/^[>|]/.test(s)) continue;
  offenders.push({ hit, s: s.slice(0, 140) });
}
if (!offenders.length) allow();

const bt = String.fromCharCode(96);
const q = (x) => bt + x + bt;
const reason =
  'BLOCKED: the closing prose promises future work, with no landing\n\n' +
  `${offenders.length} sentence(s) matched:\n` +
  offenders.slice(0, 4).map((o) => `  - "${o.hit}" -> ${o.s}${o.s.length >= 140 ? '...' : ''}`).join('\n') + '\n\n' +
  'FIX, one of three: (1) do it in this same turn  (2) ask it in this same turn with ' + q('AskUserQuestion') + '\n' +
  `  (3) give it a landing in the SAME sentence: ${q('R-<slug>')} / ${q('#<PR>')} / ${q('YYYY-MM-DD')} / ${q('batch <N>')}\n` +
  'Deleting the sentence is not one of the three.';

process.stdout.write(JSON.stringify({ decision: 'block', reason, systemMessage: 'deferral gate: the closing prose promised future work with no landing' }));

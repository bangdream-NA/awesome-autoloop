#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import {writeFileSync, mkdirSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const HOOK = join(dirname(dirname(fileURLToPath(import.meta.url))), 'require-wave-doc-read-before-dod-token.mjs');
const TMP = mkdtempSync(join(tmpdir(), 'aal-fx-'));
mkdirSync(TMP, { recursive: true });
const TOK = 'DoD-' + 'VERIFIED';

const READ_TOOL_LINE = JSON.stringify({ type: 'assistant', message: { content: [{ type: 'tool_use', name: 'Read', input: { file_path: 'Z:/wt/seogeo/docs/product-specs/R-seogeo-recovery-architecture.md' } }] } });
const BASH_READ_LINE = JSON.stringify({ type: 'assistant', message: { content: [{ type: 'tool_use', name: 'Bash', input: { command: 'git show origin/main:docs/product-specs/R-seogeo-recovery-architecture.md > /tmp/arch.md' } }] } });
const VERDICT_LINE = JSON.stringify({ type: 'assistant', message: { content: [{ type: 'tool_use', name: 'Read', input: { file_path: '/repo/.claude/reviews/pr1309-r1.md' } }] } });
const IRRELEVANT_LINE = JSON.stringify({ type: 'assistant', message: { content: [{ type: 'tool_use', name: 'Bash', input: { command: 'git status --porcelain' } }] } });

const CARD_WITH_TOKEN = '# BACKLOG\n\n### [DONE] R-sitemap-had-zero-discovered-urls-in-67-days · MERGED #1309 · ' + TOK +
  ' · stage=dev · **P0** · **PR-A merged**\n- aliases: R-seogeo-recovery, feat/r-seogeo, seogeo wave\n- log: 2026-08-12T20:00:00Z · archived\n';
const CARD_NO_TOKEN = '# BACKLOG\n\n### [IN-DEV] R-some-card · stage=dev · **P2** · **in progress**\n- aliases: x\n- log: 2026-08-12T20:00:00Z · dispatched\n';
const CARD_TOKEN_IN_BODY = '# BACKLOG\n\n### [IN-DEV] R-other-card · stage=dev · **P2** · **in progress**\n- problem: an earlier wave wrote ' + TOK + ' but that was a different card\n- log: 2026-08-12T20:00:00Z · x\n';

const judge = (cardText, transcriptLines) => {
  const tp = TMP + '/t' + Math.abs(cardText.length + transcriptLines.length) + '.jsonl';
  writeFileSync(tp, transcriptLines.join('\n') + '\n');
  const r = spawnSync(process.execPath, [HOOK], {
    input: JSON.stringify({ session_id: 'fixture', transcript_path: tp, tool_name: 'Write', tool_input: { file_path: '/repo/.claude/BACKLOG.md', content: cardText } }),
    encoding: 'utf8', timeout: 20000,
  });
  const out = ((r.stdout || '') + (r.stderr || '')).trim();
  return /"permissionDecision"\s*:\s*"deny"/.test(out) ? 'DENY' : 'ALLOW';
};

const OTHER_WAVE_READ = JSON.stringify({ type: 'assistant', message: { content: [{ type: 'tool_use', name: 'Read', input: { file_path: '/repo/docs/product-specs/R-grafana-unit-plan.md' } }] } });
const OTHER_WAVE_READ2 = JSON.stringify({ type: 'assistant', message: { content: [{ type: 'tool_use', name: 'Read', input: { file_path: '/repo/docs/product-specs/R-rating-reviews-system-plan.md' } }] } });

const PLAN_READ_LINE = JSON.stringify({ type: 'assistant', message: { content: [{ type: 'tool_use', name: 'Read', input: { file_path: 'Z:/wt/seogeo/docs/product-specs/R-seogeo-recovery-plan.md' } }] } });
const GREP_PROBE_ARCH = JSON.stringify({ type: 'assistant', message: { content: [{ type: 'tool_use', name: 'Bash', input: { command: 'grep -n "PR-A\\|PR-B\\|PR-C" docs/product-specs/R-seogeo-recovery-architecture.md' } }] } });
const GREP_PROBE_PLAN = JSON.stringify({ type: 'assistant', message: { content: [{ type: 'tool_use', name: 'Bash', input: { command: 'grep -c seogeo docs/product-specs/R-seogeo-recovery-plan.md' } }] } });

const ARMS = [
  ['A must-red — a completion token written with zero spec reads in the transcript', 'DENY', CARD_WITH_TOKEN, [IRRELEVANT_LINE]],
  ['B must-red — an entirely empty transcript (fail-closed)', 'DENY', CARD_WITH_TOKEN, []],
  ['H must-red — **a DIFFERENT wave** was read (production shape)', 'DENY', CARD_WITH_TOKEN, [OTHER_WAVE_READ, OTHER_WAVE_READ2]],
  ['I must-red — another wave plus unrelated commands, still not enough', 'DENY', CARD_WITH_TOKEN, [IRRELEVANT_LINE, OTHER_WAVE_READ]],
  ['K must-red — **production payload**: both documents are mentioned, and every contact is a grep probe', 'DENY', CARD_WITH_TOKEN, [GREP_PROBE_ARCH, GREP_PROBE_PLAN]],
  ['L must-red — read in full, but only the architecture (no plan)', 'DENY', CARD_WITH_TOKEN, [READ_TOOL_LINE]],
  ['M must-red — only the verdict file (which substitutes for ONE of them, not both)', 'DENY', CARD_WITH_TOKEN, [VERDICT_LINE]],
  ['C must-green — both read with the Read tool', 'ALLOW', CARD_WITH_TOKEN, [IRRELEVANT_LINE, READ_TOOL_LINE, PLAN_READ_LINE]],
  ['D must-red — a Bash `git show` of the architecture is NOT a whole-file read (only the Read tool counts)', 'DENY', CARD_WITH_TOKEN, [IRRELEVANT_LINE, BASH_READ_LINE, PLAN_READ_LINE]],
  ['E must-red — the verdict file **cannot substitute** for reading the plan in full (the plan was never Read)', 'DENY', CARD_WITH_TOKEN, [VERDICT_LINE, READ_TOOL_LINE]],
  ['J must-green — another wave PLUS both of this wave\u2019s documents ⇒ allow', 'ALLOW', CARD_WITH_TOKEN, [OTHER_WAVE_READ, READ_TOOL_LINE, PLAN_READ_LINE]],
  ['N must-red — one read in full plus one grep ⇒ deny ("read the docs" means EACH of them was Read)', 'DENY', CARD_WITH_TOKEN, [READ_TOOL_LINE, GREP_PROBE_PLAN]],
  ['F must-green — an ordinary write with no completion token must not be touched', 'ALLOW', CARD_NO_TOKEN, [IRRELEVANT_LINE]],
  ['G must-green — the token appears only in the BODY, where it has no effect ⇒ this gate does not fire', 'ALLOW', CARD_TOKEN_IN_BODY, [IRRELEVANT_LINE]],
];
const results = ARMS.map(([label, want, card, lines]) => {
  const got = judge(card, lines);
  const ok = got === want;
  console.log(`${ok ? 'ok  ' : 'FAIL'}  ${label}  want=${want} got=${got}`);
  return ok;
});
const failed = results.filter((x) => !x).length;
console.log(`\n${results.length - failed}/${results.length} arms pass`);
process.exit(failed ? 1 : 0);

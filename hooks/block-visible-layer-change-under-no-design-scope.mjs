#!/usr/bin/env node

import { projectPaths } from './lib/is-autoloop-lead.mjs';

export function visibleLayerHits({ changedFiles = [], diffAdded = '', diffRemoved = '' }) {
  const hits = [];
  const diff = diffAdded + '\n' + diffRemoved;
  for (const f of changedFiles) {
    if (/(^|\/)__tests__\//.test(f) || /\.(test|spec)\.[tj]sx?$/.test(f)) continue;
    if (/^docs\//.test(f) || /\.md$/.test(f)) continue;
    if (/\.css$/.test(f)) hits.push({ file: f, why: 'CSS — style IS the visible layer' });
    else if (/design-tokens\.(json|ts)$/.test(f)) hits.push({ file: f, why: 'design tokens' });
    else if (/messages\/[\w-]+\.json$/.test(f)) hits.push({ file: f, why: 'i18n copy — the words a user reads' });
    else if (/\.tsx$/.test(f)) {
      if (/^[+-].*className\s*=/m.test(diff)) hits.push({ file: f, why: 'className changed' });
      else if (/^[+-]\s*<\/?h[1-6][\s>/]/m.test(diff) || /^[+-].*\bas\s*=\s*["'{]?\s*['"]?h[1-6]\b/m.test(diff)) {
        hits.push({ file: f, why: 'heading level changed — the outline and the default type size are both visible' });
      } else if (/^-\s*<[a-zA-Z][^>]*>[^<>{}\n]*\S/m.test(diff)) {
        hits.push({ file: f, why: 'an element carrying text was deleted — visibility went from present to absent' });
      } else if (/^[+-]\s*<[a-zA-Z][^>]*>[^<>{}\n]*\S[^<>{}\n]*</m.test(diff)) hits.push({ file: f, why: 'visible text between tags changed' });
    }
  }
  return hits;
}

export const DECLARED_NO = (hay) => /design-scope:\s*(no|n\/?a|none)|VISUAL-N\/?A/i.test(hay);
export const DECLARED_YES = (hay) => /design-scope:\s*(yes|required)|DESIGN-REQUIRED/i.test(hay);
export const HAS_DESIGN_ARTIFACT = (hay) => /DESIGN[_ ]APPROVED|DESIGN DELIVERED|design doc|R-[A-Za-z0-9._-]*-design/i.test(hay);


export function decide({ cardBlock = '', prompt = '', changedFiles = [], diffAdded = '', diffRemoved = '' }) {
  const hay = cardBlock + '\n' + prompt;
  if (DECLARED_YES(hay) && HAS_DESIGN_ARTIFACT(hay)) return { deny: false, why: 'declares yes and a designer artifact exists ⇒ the correct route, allow' };
  if (!DECLARED_NO(hay)) return { deny: false, why: 'no declaration of no ⇒ not this gate\u2019s business (the dispatch gate already covers it)' };
  const hits = visibleLayerHits({ changedFiles, diffAdded, diffRemoved });
  if (!hits.length) return { deny: false, why: 'declares no and the diff touches no visible layer ⇒ allow' };
  return { deny: true, hits, why: hits.map((h) => h.file + ' — ' + h.why).join(' · ') };
}

export function denialText(branch, hits) {
  return `BLOCKED: a visible-layer change contradicts the declaration\n\n` +
    `The card for branch \`${branch}\` says **design-scope: no**, and this diff changes something a user can SEE:\n` +
    hits.map((h) => `  · ${h.file} —— ${h.why}`).join('\n') + '\n\n' +
    `**This is not a prohibition, it is a ban on doing it invisibly.** Three ways out; pick one:\n` +
    `  1. it really is a design change ⇒ set \`design-scope: yes\` on the card, dispatch a uiux-designer, and open the PR once its artifact exists\n` +
    `  2. it is not a design DECISION (say, fixing a typo, or replacing a hardcoded colour with an existing token) ⇒ in the PR body,\n` +
    `     **list these files separately** with the reason, then append \`# VISIBLE-OK: <reason>\` to the command\n` +
    `  3. split the visible-layer part out of this PR and run it through the designer on its own\n\n` +
    `**Why this gate exists**: a PR declared \`design-scope: no\` and was not lying — at plan time it really only meant to change the\n` +
    `TEXT of an h1. At implementation time the h1 went from \`sr-only\` to a **visible page heading** and a new style class appeared.\n` +
    `The existing \`require-design-scope-before-dev\` reads the declaration at the moment dev is DISPATCHED, and is structurally\n` +
    `blind to what happens during implementation. ⇒ **That gate guards the intent; this one guards the artifact.**`;
}

async function main() {
  const { readFileSync } = await import('node:fs');
  let ti = {};
  try { ti = JSON.parse(readFileSync(0, 'utf8')).tool_input ?? {}; } catch { return; }

  const cmd = String(ti.command ?? '');
  if (!/\bgh\s+pr\s+create\b/.test(cmd)) return;
  if (/#\s*VISIBLE-OK:/.test(cmd)) return;

  let board = '';
  const P = projectPaths();
  if (!P) return;
  try { board = readFileSync(P.board, 'utf8'); } catch { return; }

  const branch = (cmd.match(/--head\s+(\S+)/) || [])[1] || '';
  if (!branch) return;
  const block = board.split(/^###\s+\[/m).find((b) => b.includes(branch)) || '';
  if (!block) return;

  let files = [], added = '', removed = '';
  try {
    const { execFileSync } = await import('node:child_process');
    const run = (a) => execFileSync('git', ['-C', P.repo, ...a], { encoding: 'utf8' });
    files = run(['diff', '--name-only', `origin/main...${branch}`]).split('\n').filter(Boolean);
    const d = run(['diff', `origin/main...${branch}`]);
    added = d.split('\n').filter((l) => l.startsWith('+')).join('\n');
    removed = d.split('\n').filter((l) => l.startsWith('-')).join('\n');
  } catch { return; }

  const v = decide({ cardBlock: block, prompt: cmd, changedFiles: files, diffAdded: added, diffRemoved: removed });
  if (!v.deny) return;

  process.stdout.write(JSON.stringify({
    hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: denialText(branch, v.hits) },
  }));
}

if (process.env.AAL_FIXTURE_IMPORT !== '1') await main();

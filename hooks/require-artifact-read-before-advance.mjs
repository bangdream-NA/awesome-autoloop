#!/usr/bin/env node
import { readFileSync, existsSync, readdirSync } from 'node:fs';
import {
  specReadsForPayload, latestVerdictForPr, latestPlanVerdictForWave,
  waveTokens as waveTokensOf, tokenOverlapMatches,
} from './lib/spec-read-evidence.mjs';
import { projectPaths } from './lib/is-autoloop-lead.mjs';

function allow() { process.stdout.write('{}'); process.exit(0); }
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

let payload;
try { payload = JSON.parse(readFileSync(0, 'utf8') || '{}'); } catch { allow(); }

const tool = String(payload.tool_name || '');
const tin = payload.tool_input || {};
const REPO_ROOT = process.env.AAL_REPO_ROOT || projectPaths()?.repo || '';
const REVIEWS = process.env.AAL_REVIEWS_DIR || (REPO_ROOT + '/.claude/reviews');

const tokensOf = waveTokensOf;
const pathMatchesWave = (path, toks) => tokenOverlapMatches(path, toks);

if (tool === 'Bash') {
  const cmd = String(tin.command || '');
  const m = cmd.match(/(?:^|[;&|]\s*|\s)gh(?:\.exe)?\s+pr\s+merge\s+(\d+)/i);
  if (!m) allow();
  const pr = m[1];
  if (!existsSync(REVIEWS)) allow();
  const verdictFile = latestVerdictForPr(REVIEWS, pr);
  if (!verdictFile) allow();

  const reads = specReadsForPayload(payload);
  if (reads === null) {
    deny(`BLOCKED: the last round of code review has to be READ before PR #${pr} is merged — but **the transcript cannot be read**, so this gate can see no evidence.\n`
      + `FIX: \`Read ${REPO_ROOT}/.claude/reviews/${verdictFile}\` first, then re-run this command.\n`
      + `(fail-closed: an unreadable transcript and a transcript that genuinely shows no read are byte-identical here, so this does not allow.)`);
  }
  const stem = verdictFile.toLowerCase().replace(/\.md$/, '');
  const ok = reads.some((r) => r.viaReadTool && r.path.includes(stem));
  if (ok) allow();
  deny(`BLOCKED: the **last round** of code-review verdict has to be read before PR #${pr} is merged: \`${verdictFile}\`.\n`
    + `This turn's transcript holds no Read of it. FIX: \`Read ${REPO_ROOT}/.claude/reviews/${verdictFile}\`, then re-run.\n`
    + `grep / sed / head / tail do NOT count — reading means calling the Read tool.\n`
    + `WHY: measured — advancing on an agent's MESSAGE rather than on its ARTIFACT led to performing an action the verdict explicitly forbade.`);
}

const WT_ROOT = process.env.AAL_WT_ROOT || '';
function designDocFor(slug) {
  if (!slug) return null;
  const rel = `/docs/product-specs/R-${slug}-design.md`;
  if (existsSync(REPO_ROOT + rel)) return REPO_ROOT + rel;
  let wts = [];
  try { wts = readdirSync(WT_ROOT); } catch { return null; }
  for (const w of wts) {
    const p = WT_ROOT + '/' + w + rel;
    if (existsSync(p)) return p;
  }
  return null;
}

if (/^(Write|Edit|MultiEdit)$/.test(tool)) {
  const t5 = String(tin.file_path || '').replace(/\\/g, '/');
  const archM = t5.match(/docs\/product-specs\/R-([a-z0-9][a-z0-9-]*)-architecture\.md$/i);
  const verdM = t5.match(/\.claude\/reviews\/pr(\d+)-r(\d+)\.md$/i);

  if ((archM || verdM) && existsSync(REVIEWS)) {
    const who = archM ? 'architect' : 'code-reviewer';
    const what = archM ? `R-${archM[1]}-architecture.md` : `pr${verdM && verdM[1]}-r${verdM && verdM[2]}.md`;
    const r5 = specReadsForPayload(payload);
    if (r5 === null) {
      deny(`BLOCKED: ${who} has to Read the upstream documents in full before delivering \`${what}\` — but **the transcript cannot be read**, so this gate can see no evidence.\n`
        + `FIX: open the plan / ${archM ? 'the final plan-review verdict' : 'the architecture'} / the design (when one exists) with \`Read\`, then rewrite this artifact.\n`
        + `(fail-closed: an unreadable transcript and a transcript that shows no read are byte-identical.)`);
    }

    let slug = archM ? archM[1].toLowerCase() : '';
    if (!slug) {
      for (const r of r5) {
        const m = r.viaReadTool && r.path.match(/r-([a-z0-9][a-z0-9-]*)-(?:plan|architecture|design)\.md/i);
        if (m) { slug = m[1].toLowerCase(); break; }
      }
    }
    const wt = archM ? tokensOf(slug) : [];
    const got = (kind) => r5.some((r) => r.viaReadTool && r.kind === kind && pathMatchesWave(r.path, wt));

    const missing = [];
    if (!got('plan')) missing.push(`plan \`R-${slug || '<wave>'}-plan.md\``);

    if (archM) {
      const fv = latestPlanVerdictForWave(REVIEWS, slug);
      const vRead = fv
        ? r5.some((r) => r.viaReadTool && r.path.includes(fv.toLowerCase().replace(/\.md$/, '')))
        : got('verdict');
      if (!vRead) missing.push(fv ? `the final plan-review verdict \`${fv}\`` : "this wave's plan-review verdict");
    } else if (!got('architecture')) {
      missing.push(`architecture \`R-${slug || '<wave>'}-architecture.md\``);
    }

    const sibling = archM ? t5.replace(/-architecture\.md$/i, '-design.md') : '';
    const designPath = (sibling && existsSync(sibling)) ? sibling : designDocFor(slug);
    if (designPath && !got('design')) missing.push(`design \`R-${slug}-design.md\``);

    if (missing.length) {
      const sawK = [...new Set(r5.filter((r) => r.viaReadTool).map((r) => r.kind).filter(Boolean))];
      deny(`BLOCKED: ${who} has to Read the upstream documents in full before delivering \`${what}\`. Missing: ${missing.join(' · ')}.\n`
        + `What this gate read — spec categories Read this turn: ${sawK.length ? sawK.join(' · ') : 'none'}\n`
        + `FIX: run one \`Read\` over each missing document (the whole file, no offset/limit), then rewrite this artifact.\n`
        + `grep / sed -n / head / tail / git show do NOT count — reading means calling the Read tool.\n`
        + `NOTE: the design is required by whether the FILE EXISTS, not by the card's design-scope. If it exists, it must be read.\n`
        + `WHY: measured — three review rounds in a row passed a shipping behaviour that contradicted a line in the design document nobody had opened.`);
    }
  }
}

if (/^(Write|Edit|MultiEdit)$/.test(tool)) {
  const target = String(tin.file_path || '');
  if (!/BACKLOG[^\\/]*\.md$/i.test(target)) allow();
  if (!existsSync(REVIEWS)) allow();

  const introduced = [
    tin.content, tin.new_string,
    ...(Array.isArray(tin.edits) ? tin.edits.map((e) => e && e.new_string) : []),
  ].filter(Boolean).join('\n');
  if (!introduced) allow();

  const KIND_FOR = { design_ok: 'design', arch_approved: 'architecture', plan_approved: 'plan' };
  const headerLines = introduced.split(/\r?\n/).filter((l) => l.startsWith('### '));
  const pins = [];
  for (const l of headerLines) {
    for (const m of l.matchAll(/\b(DESIGN_OK|ARCH_APPROVED|PLAN_APPROVED)\s*@\s*([0-9a-f]{7,40})\b/gi)) {
      pins.push({ token: m[1].toUpperCase(), sha: m[2].toLowerCase(), kind: KIND_FOR[m[1].toLowerCase()] });
    }
  }
  if (!pins.length) allow();

  const waveBits = [];
  for (const l of headerLines) {
    const m = l.replace(/\[[^\]]*\]/g, ' ').match(/(R-[a-z0-9][a-z0-9-]*)/i);
    if (m) waveBits.push(m[1]);
  }
  for (const l of introduced.split(/\r?\n/)) if (/^-\s*aliases\s*:/i.test(l)) waveBits.push(l);
  const pinTokens = tokensOf(waveBits.join(' '));

  const pinReads = specReadsForPayload(payload);
  const wants = [...new Set(pins.map((p) => p.kind))];
  if (pinReads === null) {
    deny(`BLOCKED: that document has to be Read before ${pins.map((p) => p.token + ' @' + p.sha).join(' · ')} is written on a card header — `
      + `but **the transcript cannot be read**, so this gate can see no evidence.\n`
      + `FIX: ${wants.map((k) => `\`Read docs/product-specs/R-<wave>-${k}.md\``).join(' and ')}, then rewrite this line.\n`
      + `(fail-closed: an unreadable transcript and a transcript that shows no read are byte-identical.)`);
  }
  const missing = wants.filter((k) => !pinReads.some((r) => r.viaReadTool && r.kind === k
    && pathMatchesWave(r.path, pinTokens)));
  if (!missing.length) allow();

  const sawKinds = [...new Set(pinReads.filter((r) => r.viaReadTool).map((r) => r.kind).filter(Boolean))];
  deny(`BLOCKED: that document has to be Read before ${pins.map((p) => p.token + ' @' + p.sha).join(' · ')} is written on a card header. Missing: `
    + `${missing.join(' · ')}.\n`
    + `What this gate read — spec categories Read this turn: ${sawKinds.length ? sawKinds.join(' · ') : 'none'}\n`
    + `FIX: ${missing.map((k) => `\`Read docs/product-specs/R-<wave>-${k}.md\``).join(' and ')} (the whole file, `
    + `no offset/limit), then rewrite this line.\n`
    + `grep / sed -n / head / tail / git show do NOT count — reading means calling the Read tool.\n`
    + `NOTE: an existing \`- log: … · ${pins[0].token} @<sha>\` does NOT substitute: it proves someone signed at the time, not that you know today what they signed.\n`
    + `A token on a card header is YOUR assertion this turn, and readers believe it in your name.`);
}

if (tool !== 'Agent') allow();
const role = String(tin.subagent_type || '');
if (role !== 'architect' && role !== 'developer') allow();
if (!existsSync(REVIEWS)) allow();

const brief = String(tin.prompt || '') + ' ' + String(tin.name || '');
const fromPath = brief.match(/R-([a-z0-9][a-z0-9-]*)-(?:plan|architecture)\.md/i);
const waveSlug = fromPath ? fromPath[1] : '';
const waveTokens = tokensOf(waveSlug);

const reads = specReadsForPayload(payload);
if (reads === null) {
  deny(`BLOCKED: the previous baton's artifact has to be read before dispatching ${role} — but **the transcript cannot be read**, so this gate can see no evidence.\n`
    + `FIX: open the document with \`Read\`, then send this dispatch again.\n`
    + `(fail-closed: an unreadable transcript and a transcript that shows no read are byte-identical.)`);
}

const readOf = (kind) => reads.filter((r) => r.viaReadTool && r.kind === kind && pathMatchesWave(r.path, waveTokens));

if (role === 'developer') {
  if (readOf('architecture').length) allow();
  deny(`BLOCKED: the architecture has to be read before advancing to dev.\n`
    + `This turn's transcript holds no Read of${waveSlug ? ` \`R-${waveSlug}-architecture.md\`` : ' this wave\u2019s architecture'}.\n`
    + `FIX: \`Read docs/product-specs/R-${waveSlug || '<wave>'}-architecture.md\` (the whole file; grep/sed do not count), then send the dispatch again.\n`
    + `WHY: a developer implements **the spec the architecture locked**. Dispatching without reading it demotes the architecture to hearsay.`);
}

const planRead = readOf('plan').length > 0;
const finalVerdict = latestPlanVerdictForWave(REVIEWS, waveSlug);
const verdictRead = finalVerdict
  ? reads.some((r) => r.viaReadTool && r.path.includes(finalVerdict.toLowerCase().replace(/\.md$/, '')))
  : readOf('verdict').length > 0;

if (planRead && verdictRead) allow();

const missing = [];
if (!verdictRead) missing.push(finalVerdict ? `the final verdict \`${finalVerdict}\`` : "this wave's plan-review verdict");
if (!planRead) missing.push(`plan \`R-${waveSlug || '<wave>'}-plan.md\``);
deny(`BLOCKED: the FINAL review verdict and the plan both have to be read before advancing to arch. Missing: ${missing.join(' · ')}.\n`
  + `FIX: open each of the above in full with \`Read\`, then send this dispatch again. grep / sed / head / tail do not count.\n`
  + `WHY (measured; this gate exists because of it): a plan-reviewer's verdict said, verbatim, that a set of\n`
  + `problems must NOT be fixed in that wave. The lead read only the MESSAGE the reviewer sent and never opened\n`
  + `the verdict file, and dispatched an architect to do the very thing it forbade. **A message notifies; the artifact instructs.**\n`
  + `NOTE: it has to be the FINAL round — an earlier verdict cannot prove what the last one decided.`);

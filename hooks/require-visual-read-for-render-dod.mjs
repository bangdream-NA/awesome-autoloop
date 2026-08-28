#!/usr/bin/env node
import { readFileSync, readdirSync, statSync } from 'node:fs';
import path from 'node:path';

let stdin = {};
try { stdin = JSON.parse(readFileSync(0, 'utf8') || '{}'); } catch { stdin = {}; }
const transcriptPath = String(stdin.transcript_path || '');
const tp = transcriptPath.replace(/\\/g, '/');
const HOME_SLUG = homeDir().replace(/[^A-Za-z0-9]/g, '-');
if (tp && !tp.toLowerCase().includes(`/projects/${HOME_SLUG.toLowerCase()}/`)) { process.stdout.write('{}'); process.exit(0); }

const DIR = process.env.AAL_VISUALGATE_DIR || projectPaths()?.claude || '';
let oplog = '';
let ownsProject = false;
let ledgers = [];
try {
  const files = readdirSync(DIR)
    .filter((f) => /^autoloop-log-.*\.md$/.test(f))
    .map((f) => { try { return { f, m: statSync(path.join(DIR, f)).mtimeMs }; } catch { return null; } })
    .filter(Boolean)
    .filter((x) => Date.now() - x.m < 7 * 24 * 3600 * 1000)
    .sort((a, b) => a.m - b.m);
  ledgers = files.map((x) => ({
    sid8: ((x.f.match(/-([0-9a-f]{8})\.md$/i) || [])[1] || '').toLowerCase(),
    lines: readFileSync(path.join(DIR, x.f), 'utf8').split('\n').slice(-400),
  }));
  oplog = ledgers.map((L) => L.lines.join('\n')).join('\n');
  const newest = files[files.length - 1];
  const sidm = newest && newest.f.match(/-([0-9a-f]{8})\.md$/i);
  ownsProject = !!(sidm && String(stdin.session_id || '').toLowerCase().startsWith(sidm[1].toLowerCase()));
} catch { process.stdout.write('{}'); process.exit(0); }
if (!oplog) { process.stdout.write('{}'); process.exit(0); }

const allEntries = ledgers.flatMap((L) => L.lines.map((l) => ({ l, sid8: L.sid8 })));
const recentEntries = allEntries.slice(-150);
try {
  const BOARD = (process.env.AAL_BACKLOG || projectPaths()?.board || '');
  for (const l of readFileSync(BOARD, 'utf8').split('\n')) {
    if (!l.startsWith('### ')) continue;
    if (!/DoD-VERIFIED/.test(l)) continue;
    recentEntries.push({ l, sid8: String(stdin.session_id || '').slice(0, 8).toLowerCase() });
  }
} catch {  }
const recent = [recentEntries.map((e) => e.l).join('\n')];
const isVerified = (r) =>
  /DoD[-\s]?(VERIFIED|PASS)|VERIFIED LIVE|visual read|visually (?:verified|checked)|visual confirmation/i.test(r) ||
  /\b(?:passed|accepted|acceptance (?:complete|passed|done)|walk complete|closed the loop|all three legs hold|end-to-end (?:passes|holds|verified))\b/i.test(r) ||
  /\b(journey|walk|end[-\s]?to[-\s]?end)\b[^\n]{0,40}\b(done|complete|verified|passed|green)\b/i.test(r);
const isRenderSurface = (r) =>
  /(render|screenshot|visual|Playwright|friendly HTML|live page|live walk|browser|\bUI\b|empty[-\s]?state|\bpage\b|button|chrome|CSS|layout|glyph|arrow|user[-\s]?facing|DoD walk|footer|masthead)/i.test(r);
const recentLines = recent.join('\n').split('\n');
const claimEntries = recentEntries.filter((e) => isVerified(e.l) && isRenderSurface(e.l));

const hasSubstantiveNA = (l) => /(?:VISUAL[-\s]?N\/?A|visual not applicable|cannot be screenshotted):[^\n]{15,}/i.test(l);
const nonNA = claimEntries.filter((e) => !hasSubstantiveNA(e.l));

import { openSync, readSync, closeSync, fstatSync } from 'node:fs';
import { autoLogOnDeny } from './lib/log-denial.mjs';
import { projectPaths } from './lib/is-autoloop-lead.mjs';
import { homeDir } from './lib/is-autoloop-lead.mjs';
autoLogOnDeny('require-visual-read-for-render-dod');
const TAIL_CAP = 48 * 1024 * 1024;
const readTailBounded = (p) => {
  const fd = openSync(p, 'r');
  try {
    const size = fstatSync(fd).size;
    const len = Math.min(size, TAIL_CAP);
    const buf = Buffer.alloc(len);
    readSync(fd, buf, 0, len, size - len);
    return buf.toString('utf8');
  } finally { closeSync(fd); }
};
const HAS_TOOLUSE = /"type"\s*:\s*"tool_use"/;
const TDIR = transcriptPath
  ? path.dirname(transcriptPath)
  : `${homeDir()}/.claude/projects/${String(process.env.CLAUDE_PROJECT_DIR || homeDir()).replace(/[^A-Za-z0-9]/g, '-')}`;
let transcriptTail = '';
try {
  if (transcriptPath) transcriptTail = readTailBounded(transcriptPath);
  if (!HAS_TOOLUSE.test(transcriptTail)) {
    const sid = String(stdin.session_id || '');
    const sibs = readdirSync(TDIR)
      .filter((f) => /\.jsonl$/.test(f))
      .map((f) => { try { return { f, m: statSync(path.join(TDIR, f)).mtimeMs }; } catch { return null; } })
      .filter(Boolean)
      .sort((a, b) => b.m - a.m);
    for (const s of sibs) {
      let t = '';
      try { t = readTailBounded(path.join(TDIR, s.f)); } catch { continue; }
      if (HAS_TOOLUSE.test(t) && sid && t.includes('"sessionId":"' + sid + '"')) { transcriptTail = t; break; }
    }
  }
  if (!HAS_TOOLUSE.test(transcriptTail)) {
    process.stdout.write('{}'); process.exit(0);
  }
} catch { process.stdout.write('{}'); process.exit(0); }

const writeToolLines = transcriptTail
  .split('\n')
  .filter((l) => /"type"\s*:\s*"tool_use"/.test(l) && /"name"\s*:\s*"(Bash|Edit|Write|MultiEdit)"/.test(l))
  .join('\n');
const authoredThisSession = (r) => {
  if (!transcriptTail) return true;
  const frags = (r.match(/[^"\\\n]{16,60}/g) || []).sort((a, b) => b.length - a.length);
  if (!frags.length) return true;
  return writeToolLines.includes(frags[0].trim());
};
const enforced = nonNA.filter((e) => ownsProject || authoredThisSession(e.l));

const IMG_RE = /"media_type"\s*:\s*"image\/[a-z]+"\s*,\s*"data"\s*:\s*"[A-Za-z0-9+/]{200,}/gi;
const imgPos = [];
for (const m of transcriptTail.matchAll(IMG_RE)) imgPos.push(m.index);
const READIMG_RE = /"name"\s*:\s*"Read"[^\n]{0,400}?"file_path"\s*:\s*"[^"]+\.(?:png|jpe?g|webp|gif)"/gi;
for (const m of transcriptTail.matchAll(READIMG_RE)) imgPos.push(m.index);
const ADJ = 8 * 1024 * 1024;

const SCROLLBARS_RE = /setScrollbarsHidden/g;
const sbPos = [];
for (const m of transcriptTail.matchAll(SCROLLBARS_RE)) sbPos.push(m.index);
const MOBILE_CLAIM_RE = /\b(?:375|390|412|414|360)\s*[×x]\s*\d{3}|\bmobile\b|\bphone\b|mobile\s*(?:walk|viewport)|real device|device\s*head/i;
const isMobileClaim = (e) => MOBILE_CLAIM_RE.test(String(e.l || ''));

const mySid8 = String(stdin.session_id || '').slice(0, 8).toLowerCase();
const scanImgs = (t) => {
  const pos = [];
  for (const m of t.matchAll(IMG_RE)) pos.push(m.index);
  for (const m of t.matchAll(READIMG_RE)) pos.push(m.index);
  return pos;
};
const foreignCache = new Map();
const resolveForeign = (sid8) => {
  if (foreignCache.has(sid8)) return foreignCache.get(sid8);
  let out = null;
  try {
    const own = readdirSync(TDIR).find((f) => f.toLowerCase().startsWith(sid8) && /\.jsonl$/i.test(f));
    if (own) {
      let t = readTailBounded(path.join(TDIR, own));
      if (!HAS_TOOLUSE.test(t)) {
        const fullId = own.replace(/\.jsonl$/i, '');
        const sibs = readdirSync(TDIR)
          .filter((f) => /\.jsonl$/i.test(f) && f !== own)
          .map((f) => { try { return { f, m: statSync(path.join(TDIR, f)).mtimeMs }; } catch { return null; } })
          .filter(Boolean)
          .sort((a, b) => b.m - a.m);
        t = '';
        for (const s of sibs) {
          let st = '';
          try { st = readTailBounded(path.join(TDIR, s.f)); } catch { continue; }
          if (HAS_TOOLUSE.test(st) && st.includes('"sessionId":"' + fullId + '"')) { t = st; break; }
        }
      }
      if (t && HAS_TOOLUSE.test(t)) out = { tail: t, imgPos: scanImgs(t) };
    }
  } catch { out = null; }
  foreignCache.set(sid8, out);
  return out;
};
const isWriteToolLine = (line) =>
  /"type"\s*:\s*"tool_use"/.test(line) && /"name"\s*:\s*"(Bash|Edit|Write|MultiEdit)"/.test(line);
const posOfWrite = (frag) => {
  if (!frag) return -1;
  let idx = transcriptTail.indexOf(frag);
  while (idx >= 0) {
    const ls = transcriptTail.lastIndexOf('\n', idx) + 1;
    const le = transcriptTail.indexOf('\n', idx);
    if (isWriteToolLine(transcriptTail.slice(ls, le < 0 ? transcriptTail.length : le))) return idx;
    idx = transcriptTail.indexOf(frag, idx + 1);
  }
  return -1;
};
const claimSatisfied = (e) => {
  const frags = (e.l.match(/[^"\\\n]{16,60}/g) || []).sort((a, b) => b.length - a.length);
  const frag = frags.length ? frags[0].trim() : '';
  const pos = posOfWrite(frag);
  if (pos >= 0) {
    const unreachable = (transcriptTail.length - pos) > ADJ;
    const sawImage = imgPos.some((p) => Math.abs(p - pos) <= ADJ);
    if (!sawImage) return unreachable;
    if (isMobileClaim(e)) return sbPos.some((p) => Math.abs(p - pos) <= ADJ) || unreachable;
    return true;
  }
  if (e.sid8 && mySid8 && e.sid8 !== mySid8) {
    const fe = resolveForeign(e.sid8);
    if (!fe) return true;
    const fpos = frag ? fe.tail.indexOf(frag) : -1;
    if (fpos >= 0) return fe.imgPos.some((p) => Math.abs(p - fpos) <= ADJ);
    return fe.imgPos.length > 0;
  }
  return true;
};
const unsatisfied = enforced.filter((e) => !claimSatisfied(e));

const prTok = /#(\d{3,4})(?!\d)/g;
const MERGE_ANCHOR = /\bMERGED?\s*(?:PR\s*)?#(\d{3,4})(?!\d)/gi;
const mergePRs = new Map();
for (const e of recentEntries) {
  if (!isRenderSurface(e.l)) continue;
  if (!(ownsProject || authoredThisSession(e.l))) continue;
  for (const m of e.l.matchAll(MERGE_ANCHOR)) mergePRs.set(m[1], e);
}
const clearedPRs = new Set();
for (const l of recentLines) {
  if (!(isVerified(l) || hasSubstantiveNA(l) || /DoD[-\s]?(GATED|BLOCKED)/i.test(l))) continue;
  for (const m of l.matchAll(prTok)) clearedPRs.add(m[1]);
}
const nakedMerges = [...mergePRs.keys()].filter((pr) => !clearedPRs.has(pr) && !claimSatisfied(mergePRs.get(pr)));

const ARCH_DOD = /DoD[-\s]?(VERIFIED|met|✅)|LIVE[-\s]?(verified|confirmed)|DONE\+LIVE/i;
let archiveUnsatisfied = [];
try {
  const af = path.join(DIR, 'BACKLOG-archive.md');
  if (Date.now() - statSync(af).mtimeMs < 7 * 24 * 3600 * 1000) {
    const alines = readFileSync(af, 'utf8').split('\n');
    const blocks = [];
    let cur = null;
    for (const ln of alines) {
      if (/^### /.test(ln)) { if (cur) blocks.push(cur); cur = { h: ln, body: [] }; }
      else if (cur) cur.body.push(ln);
    }
    if (cur) blocks.push(cur);
    archiveUnsatisfied = blocks.filter((b) => {
      if (!ARCH_DOD.test(b.h)) return false;
      const block = b.h + '\n' + b.body.join('\n');
      if (!isRenderSurface(block)) return false;
      if (block.split('\n').some(hasSubstantiveNA)) return false;
      const frags = (b.h.match(/[^"\\\n]{16,60}/g) || []).sort((x, y) => y.length - x.length);
      const frag = frags.length ? frags[0].trim() : '';
      const pos = posOfWrite(frag);
      if (pos < 0) return false;
      if ((transcriptTail.length - pos) > ADJ) return false;
      return !imgPos.some((p) => Math.abs(p - pos) <= ADJ);
    });
  }
} catch { archiveUnsatisfied = []; }

if (!unsatisfied.length && !nakedMerges.length && !archiveUnsatisfied.length) { process.stdout.write('{}'); process.exit(0); }

const partA = unsatisfied.length
  ? `the op-log carries a render / user-facing DoD-VERIFIED claim, and this session's transcript holds **no real image-Read adjacent to that claim** (an old screenshot cannot vouch for a new claim) — a curl header, a page title, a DOM proxy and byte identity are all ways of going around it.`
  : '';
const partB = nakedMerges.length
  ? `these render waves have had NO visual DoD at all since they merged (no visual DoD-VERIFIED row, no substantive VISUAL-N/A, no DoD-GATED): PR #${nakedMerges.join(', #')} (the anchor is the structural token \`MERGE PR #N\` / \`MERGED #N\` inside a ledger row) — "merged a render wave and never once image-Read it" is the sharpest escape of all.`
  : '';
const partC = archiveUnsatisfied.length
  ? `archive mis-declaration check: a render card newly archived in this session claims a DoD on its ### header line, and the transcript holds no adjacent image evidence — an archive token is a CLAIM, not evidence: ${archiveUnsatisfied.map((b) => b.h.slice(4, 84)).join(' / ')}`
  : '';
const parts = [partA, partB, partC].filter(Boolean).join('\nAND ');
process.stdout.write(JSON.stringify({
  decision: 'block',
  reason:
    `BLOCKED: a visual check is required: ${parts}\nDo it now: (1) take a Playwright screenshot to an absolute path under your scratch dir; (2) actually READ that .png with the Read tool (look at the image); (3) write what you SAW (layout / copy / empty state / UX) plus the PR number into the card and the op-log, then stop. For a genuinely unreachable surface write "VISUAL-N/A: <specific reason, 15+ chars>"; a bare VISUAL-N/A does not exempt.\nIf the claim mentions a mobile viewport (375/390/... x ... · mobile · real device) the screenshot has to be taken under all five CDP commands: \`setUserAgentOverride\` (UA string plus \`userAgentMetadata.mobile\`) · \`setTouchEmulationEnabled\` · \`setEmulatedMedia\` (pointer:coarse / hover:none) · \`setScrollbarsHidden({hidden:true})\` · \`setDeviceMetricsOverride\`, then reload.\nWithout \`setScrollbarsHidden\` the desktop scrollbar eats 15 CSS px, a "390 wide" walk is really 375, and the browser chrome gets misreported as a site defect. Print \`innerWidth - documentElement.clientWidth\` beside the conclusion; non-zero voids it.`,
}));
process.exit(0);

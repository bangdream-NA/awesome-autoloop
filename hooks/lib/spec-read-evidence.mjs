import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { readTranscriptText } from './transcript-last-assistant.mjs';
import { homeDir } from './is-autoloop-lead.mjs';

export const SEP = '(?:[\\\\/]|\\\\\\\\)';

export const SPEC_RE = new RegExp(
  `docs${SEP}product-specs${SEP}R-[^"'\\s]*-(?:plan|architecture|design)\\.md`
  + `|\\.claude${SEP}reviews${SEP}[^"'\\s]*\\.md`, 'i');

export const KEYWORD_PROBE_RE = /\b(?:grep|rg|egrep|fgrep|wc|awk)\b|\|\s*head\b|\|\s*tail\b|\bhead\s+-|\btail\s+-/i;

export const READ_FRESH_MS = 4 * 60 * 60 * 1000;
export const READ_TAIL_LINES = 8000;

export function kindOf(p) {
  return /-architecture\.md$/i.test(p) ? 'architecture'
    : /-plan\.md$/i.test(p) ? 'plan'
      : /-design\.md$/i.test(p) ? 'design'
        : /[\\/]reviews[\\/]/i.test(p) ? 'verdict' : null;
}

export function resolveTranscriptPath(payload) {
  if (payload.transcript_path && existsSync(payload.transcript_path)) return payload.transcript_path;
  const base = homeDir() + '/.claude/projects';
  if (!existsSync(base)) return null;
  let best = null;
  for (const d of readdirSync(base)) {
    const dir = base + '/' + d;
    let ents = [];
    try { ents = readdirSync(dir); } catch { continue; }
    for (const f of ents) {
      if (!f.endsWith('.jsonl')) continue;
      if (payload.session_id && !f.includes(String(payload.session_id))) continue;
      const p = dir + '/' + f;
      let st; try { st = statSync(p); } catch { continue; }
      if (!best || st.mtimeMs > best.m) best = { p, m: st.mtimeMs };
    }
  }
  return best ? best.p : null;
}

export function scanSpecReads(transcriptText) {
  const out = [];
  if (!transcriptText) return out;
  for (const ln of transcriptText.split(/\r?\n/)) {
    if (!/"name"\s*:\s*"(?:Read|Bash)"/.test(ln)) continue;
    const m = ln.match(SPEC_RE);
    if (!m) continue;
    const path = m[0].toLowerCase();
    out.push({ path, kind: kindOf(path), viaReadTool: /"name"\s*:\s*"Read"/.test(ln) });
  }
  return out;
}

export function specReadsForPayload(payload) {
  const tp = resolveTranscriptPath(payload);
  if (!tp) return null;
  let text = '';
  try { text = readTranscriptText(tp).text; } catch { text = ''; }
  if (!text) return null;
  return scanSpecReads(text);
}

export function latestVerdictForPr(reviewsDir, pr) {
  try {
    const cands = readdirSync(reviewsDir)
      .filter((f) => new RegExp(`^pr${pr}-r\\d+\\.md$`).test(f))
      .sort((a, b) => Number(a.match(/r(\d+)/)[1]) - Number(b.match(/r(\d+)/)[1]));
    return cands.length ? cands[cands.length - 1] : null;
  } catch { return null; }
}

export const waveTokens = (s) => String(s).toLowerCase().split(/[^a-z0-9]+/).filter((t) => t.length >= 3);

export const tokenOverlapMatches = (haystack, toks) => {
  if (!toks.length) return true;
  const h = String(haystack).toLowerCase();
  let hits = 0;
  for (const t of toks) if (h.includes(t)) hits += 1;
  return hits >= Math.min(2, toks.length);
};

function verdictFromLedger(reviewsDir, wave) {
  const want = String(wave).toLowerCase().replace(/^r-/, '');
  if (!want) return null;
  let lines;
  try { lines = readFileSync(reviewsDir + '/index.jsonl', 'utf8').split(/\r?\n/); } catch { return null; }
  let best = null;
  for (const ln of lines) {
    if (!ln.trim()) continue;
    let row;
    try { row = JSON.parse(ln); } catch { continue; }
    if (String(row.plan || '').toLowerCase().replace(/^r-/, '') !== want) continue;
    const base = String(row.file || '').split(/[\\/]/).pop();
    if (!/planrev-r\d+\.md$/i.test(base)) continue;
    const rd = Number(row.round);
    if (!Number.isFinite(rd)) continue;
    if (!best || rd > best.round) best = { round: rd, file: base };
  }
  return best ? best.file : null;
}

export function latestPlanVerdictForWave(reviewsDir, wave) {
  const fromLedger = verdictFromLedger(reviewsDir, wave);
  if (fromLedger) return fromLedger;
  const toks = waveTokens(wave);
  if (!toks.length) return null;
  try {
    const cands = readdirSync(reviewsDir)
      .filter((f) => /planrev-r\d+\.md$/i.test(f) && tokenOverlapMatches(f, toks))
      .sort((a, b) => Number(a.match(/r(\d+)/)[1]) - Number(b.match(/r(\d+)/)[1]));
    return cands.length ? cands[cands.length - 1] : null;
  } catch { return null; }
}

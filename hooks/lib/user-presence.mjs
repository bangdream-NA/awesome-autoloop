
import { openSync, fstatSync, readSync, closeSync } from 'node:fs';

export const RECENT_MS = 60 * 60 * 1000;

export const TAIL_BYTES = 8 * 1024 * 1024;

export function readTranscriptTail(path, bytes = TAIL_BYTES) {
  let fd = null;
  try {
    fd = openSync(path, 'r');
    const size = fstatSync(fd).size;
    const len = Math.min(size, bytes);
    const buf = Buffer.allocUnsafe(len);
    readSync(fd, buf, 0, len, size - len);
    const lines = buf.toString('utf8').split(/\r?\n/).filter(Boolean);
    return len < size ? lines.slice(1) : lines;
  } catch {
    return null;
  } finally {
    if (fd !== null) { try { closeSync(fd); } catch {  } }
  }
}


const TYPED_RE = /"promptSource"\s*:\s*"(?:typed|queued)"/;

const META_RE = /"isMeta"\s*:\s*true/;

const QC_CANDIDATE_RE = /"queued_command"/;
const HUMAN_RE = /"kind"\s*:\s*"human"/;


function queuedHumanTs(line) {
  if (!QC_CANDIDATE_RE.test(line) || !HUMAN_RE.test(line)) return null;
  let o;
  try { o = JSON.parse(line); } catch { return null; }
  const a = o && o.attachment;
  if (!a || a.type !== 'queued_command') return null;
  if (!a.origin || a.origin.kind !== 'human') return null;
  if (a.isMeta === true) return null;
  const t = Date.parse(a.timestamp || o.timestamp || '');
  return Number.isNaN(t) ? null : t;
}

export function userPresenceFrom(lines, nowMs = Date.now()) {
  const arr = Array.isArray(lines) ? lines : [];
  let legA = null;
  let legB = null;
  for (let i = arr.length - 1; i >= 0 && (legA === null || legB === null); i--) {
    const l = String(arr[i] || '');
    if (legA === null && /"type"\s*:\s*"user"/.test(l) && TYPED_RE.test(l) && !META_RE.test(l)) {
      const m = l.match(/"timestamp"\s*:\s*"([^"]+)"/);
      const t = m ? Date.parse(m[1]) : NaN;
      if (!Number.isNaN(t)) legA = t;
    }
    if (legB === null) {
      const t = queuedHumanTs(l);
      if (t !== null) legB = t;
    }
  }
  if (legA === null && legB === null) return { present: false, ageMs: null };
  const newest = Math.max(legA === null ? -Infinity : legA, legB === null ? -Infinity : legB);
  const ageMs = nowMs - newest;
  return { present: ageMs < RECENT_MS, ageMs };
}

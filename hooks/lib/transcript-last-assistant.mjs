
import { readFileSync, openSync, readSync, closeSync, fstatSync } from 'node:fs';

export const TAIL_BYTES = 32 * 1024 * 1024;
export function readTranscriptText(tp) {
  try { return { text: readFileSync(tp, 'utf8'), truncated: false }; } catch {  }
  try {
    const fd = openSync(tp, 'r');
    try {
      const size = fstatSync(fd).size;
      const len = Math.min(size, TAIL_BYTES);
      const buf = Buffer.allocUnsafe(len);
      readSync(fd, buf, 0, len, size - len);
      return { text: buf.toString('utf8'), truncated: len < size };
    } finally { closeSync(fd); }
  } catch { return { text: '', truncated: false }; }
}

export function lastAssistantText(input) {
  const tp = input && input.transcript_path;
  if (!tp || typeof tp !== 'string') return '';

  const { text: raw } = readTranscriptText(tp);
  if (!raw) return '';

  let lastText = '';
  for (const line of raw.split(/\r?\n/)) {
    if (!line.trim()) continue;
    let j; try { j = JSON.parse(line); } catch { continue; }
    const m = j && j.message;
    if (!m || m.role !== 'assistant') continue;
    const parts = Array.isArray(m.content) ? m.content : [];
    const text = parts.filter((p) => p && p.type === 'text').map((p) => p.text || '').join('\n');
    if (text.trim()) lastText = text;
  }
  return lastText;
}

export function stripQuoted(s) {
  return String(s || '')
    .replace(/`[^`]*`/g, ' ')
    .replace(/[\u201C\u2018][^\u201D\u2019]*[\u201D\u2019]/g, ' ');
}

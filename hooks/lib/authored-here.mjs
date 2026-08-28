import { readFileSync } from 'node:fs';

export function loadWriteToolLines(transcriptPath) {
  try {
    if (!transcriptPath) return '';
    return readFileSync(transcriptPath, 'utf8')
      .split('\n')
      .filter((l) => /"type"\s*:\s*"tool_use"/.test(l) && /"name"\s*:\s*"(Bash|Edit|Write|MultiEdit)"/.test(l))
      .join('\n');
  } catch {
    return '';
  }
}

export function authoredHere(writeToolLines, text) {
  if (!writeToolLines) return true;
  const frags = (String(text).match(/[^"\\\n]{16,60}/g) || []).sort((a, b) => b.length - a.length);
  if (!frags.length) return true;
  return writeToolLines.includes(frags[0].trim());
}

export function cardAuthoredHere(writeToolLines, cardText) {
  const lines = String(cardText)
    .split('\n')
    .filter((l) => /^###\s/.test(l) || /^\s*-\s*20\d\d-\d\d-\d\d/.test(l))
    .slice(0, 40);
  return lines.some((l) => authoredHere(writeToolLines, l));
}

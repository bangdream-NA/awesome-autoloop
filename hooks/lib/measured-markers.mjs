
export const MEASURED_RE = new RegExp([
  '`[^`\\n]*\\b(?:git|grep|rg|node|bash|sh|pnpm|gh|curl|ssh|awk|sed|wc|test)\\b[^`\\n]*`',
  '\\brc\\s*=\\s*\\d+',
  '\\b[\\w./-]+\\.\\w{1,5}:\\d+\\b',
  '20\\d\\d-\\d\\d-\\d\\d',
  '\\b(?:measured|I ran|I measured|first-hand|read back)\\b',
  'measured|I ran|I measured|first-hand|read back',
].join('|'), 'i');

export const RULED_OUT_RE = new RegExp([
  '\\b(?:ruled out|rules out|excluded|eliminates?|not the cause|falsifi(?:es|ed))\\b',
  '\\bcontrol\\b[^\\n]{0,40}(?:fires?|fired|hit|non-zero|has teeth)',
  'must-hit control|ruled out|falsified|other direction|both legs|both ends|changed corpus',
  '\\broot cause\\b|\\btrue cause\\b',
].join('|'), 'i');

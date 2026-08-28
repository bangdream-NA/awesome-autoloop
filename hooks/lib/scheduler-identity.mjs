


export const OWNERSHIP_SPELLINGS =  ([
  {
    id: 'numeric-ack',
    applies: 'card body',
    describe: 'MERGED #N / PR #N — unanchored (markdown decoration) and case-SENSITIVE',
  },
  {
    id: 'header-name',
    applies: 'card header',
    describe: 'the name position equals an identity token of the merge — EQUALITY, not substring',
  },
  {
    id: 'alias-entry',
    applies: 'card body',
    describe: 'an `- aliases:` token equals an identity token of the merge — EXACT, never a substring',
  },
  {
    id: 'branch-slug',
    applies: 'card body',
    describe: 'the merge branch slug appears as a WHOLE TOKEN in the body (not `includes`)',
  },
]);


export const NON_SPELLINGS =  (['bare-#N']);

export const numericAckRe = (n) => new RegExp(`(?:MERGED\\s*#|PR\\s*#)${n}\\b`);


export const bareRefRe = (n) => new RegExp(`#${n}\\b`);

const LEFT_EDGE = '[^A-Za-z0-9_]';
const RIGHT_EDGE = '[^A-Za-z0-9_-]';
export function wholeTokenRe(slug) {
  const esc = String(slug).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return new RegExp(`(?:^|${LEFT_EDGE})${esc}(?:$|${RIGHT_EDGE})`);
}


export const containsWholeToken = (text, slug) => !!slug && wholeTokenRe(slug).test(String(text));

export const ALIAS_LINE_RE = /^\s*[-*]?\s*aliases\s*:\s*(.+)$/m;


export function aliasesOf(blockText) {
  const m = String(blockText || '').match(ALIAS_LINE_RE);
  if (!m) return [];
  return m[1].split(',').map((x) => x.trim()).filter(Boolean);
}

export const HEADER_GRAMMARS =  ([
  /^###\s+\[[^\]]+\]\s+([A-Za-z0-9._-]+)/,
  /^###\s+[^\s\w]{1,3}\s*\[[^\]]+\]\s+([A-Za-z0-9._-]+)/,
  /^###\s+[^\s\w]{1,3}\s+(?:DONE|MERGED)\s+(R-[A-Za-z0-9._-]+)/,
  /^###\s+(?:DONE|MERGED)\s+(R-[A-Za-z0-9._-]+)/,
  /^###\s+[^\s\w]{1,3}\s+(R-[A-Za-z0-9._-]+)/,
  /^###\s+(R-[A-Za-z0-9._-]+)/,
  /^###\s+(?:(?:[^\s\w]{1,3}|DONE|MERGED|\[[^\]]+\]|#\d+)\s+){1,5}(R-[A-Za-z0-9._-]+)/,
  /^###[^\n]{0,120}?·\s*(R-[A-Za-z0-9._-]+)[^\n]*·/,
  /^###\s+(?:[^\s\w]{1,3}\s+)?((?:wave|r\d+)-[a-z0-9][a-z0-9-]+)/,
  /^###\s+(?:[^\s\w]{1,3}|T-\d+)[^·\n]{0,80}?\s(R-[A-Za-z0-9._-]+)/,
]);

export const SLUG_SHAPED_RE = /(?:R-[a-z0-9][a-z0-9-]{4,}|wave-[a-z0-9][a-z0-9-]{3,}|^###\s+T-\d+\s)/i;

export const RECORD_BULLET_RE = /^\s*[-*]\s+\*\*[^*\n]+\*\*\s*·/;

export function classifyHeader(line) {
  if (headerName(line)) return 'card';
  return SLUG_SHAPED_RE.test(line) ? 'unclassified' : 'non-card';
}

export function headerName(line) {
  for (let i = 0; i < HEADER_GRAMMARS.length; i += 1) {
    const m = String(line).match(HEADER_GRAMMARS[i]);
    if (m) return { name: m[1], grammar: i };
  }
  return null;
}

export function enumerateCards(boardText) {
  const lines = String(boardText || '').split(/\r?\n/);
  const cards = [];
  const nonCards = [];
  let headerCount = 0;
  let bulletRecords = 0;
  
  let cur = null;

  const flush = () => {
    if (cur) cards.push({
      name: cur.name, grammar: cur.grammar, header: cur.header, line: cur.line,
      block: cur.body.join('\n'),
    });
    cur = null;
  };

  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i];
    if (/^###\s/.test(line)) {
      headerCount += 1;
      flush();
      const h = headerName(line);
      if (h) cur = { name: h.name, grammar: h.grammar, header: line, line: i + 1, body: [line] };
      else nonCards.push({ line: i + 1, text: line, kind: classifyHeader(line) });
    } else if (RECORD_BULLET_RE.test(line)) {
      bulletRecords += 1;
    } else if (cur) {
      cur.body.push(line);
    }
  }
  flush();
  return { cards, nonCards, headerCount, bulletRecords };
}

export function identityTokens(meta) {
  const s = new Set();
  if (!meta) return s;
  const b = String(meta.branch || '').replace(/^(feat|fix|docs|chore|refactor|test)\//, '');
  if (b) {
    s.add(b);
    if (/^r-/i.test(b)) s.add(b.replace(/^r-/i, 'R-'));
  }
  for (const m of String(meta.title || meta.subject || '').matchAll(/R-[a-z0-9][a-z0-9-]{4,}/gi)) s.add(m[0]);
  return s;
}

export function spellingFor(card, pr, meta) {
  const headerAck = /(?:MERGED\s*#|PR\s*#)\d{2,5}\b/.test(card.header);
  if (numericAckRe(pr).test(headerAck ? card.header : card.block)) return 'numeric-ack';

  const tokens = identityTokens(meta);
  for (const t of tokens) if (card.name === t) return 'header-name';

  const aliases = aliasesOf(card.block);
  for (const a of aliases) for (const t of tokens) if (a === t) return 'alias-entry';

  for (const t of tokens) if (containsWholeToken(card.block, t)) return 'branch-slug';

  return null;
}

export function resolveOwnership(cards, pr, meta) {
  const hits = [];
  for (const c of cards) {
    const sp = spellingFor(c, pr, meta);
    if (sp) hits.push({ card: c.name, spelling: sp });
  }
  if (!hits.length) return { owner: null, spelling: null, ambiguous: null };

  const rank = (sp) => OWNERSHIP_SPELLINGS.findIndex((s) => s.id === sp);
  const best = Math.min(...hits.map((h) => rank(h.spelling)));
  const top = hits.filter((h) => rank(h.spelling) === best);

  const names = [...new Set(top.map((h) => h.card))];
  if (names.length === 1) return { owner: names[0], spelling: top[0].spelling, ambiguous: null };
  return { owner: null, spelling: OWNERSHIP_SPELLINGS[best].id, ambiguous: names };
}

export const OWNERSHIP_HELP = OWNERSHIP_SPELLINGS.map((s) => `${s.id}(${s.applies})`).join('  ·  ');


const COMMON = String.raw`\b[0-9a-f]{7,40}\b`
  + '|- ?log:'
  + String.raw`|\d{4}-\d{2}-\d{2}T\d{2}:[0-9x]{2}`
  + '|\\b(?:already)\\s+(?:pushed|changed|merged|logged|dispatched|landed|deleted|created|ran|done|closed|archived|corrected|adopted|authorised)\\b'
  + '|rc=0';


export const LANDED_RE = new RegExp(`${COMMON}|\\b(?:changed|pushed|logged|dispatched|ran|did)\\s+(?:it|that|them)?\\s*(?:already)?\\b`);

export const LANDED_STRICT_RE = new RegExp(
  `${COMMON}`
  + '|(?:changed|pushed|logged|dispatched|ran|did|added|adopted|fixed|created|verified|tested|swept|landed)\\b'
  + '|\\b(?:already|have|has)\\s+(?:done|added|adopted|run|changed|fixed|created|dispatched|pushed|verified|tested|swept|landed)\\b'
  + '|\\bcompleted\\b|\\bwritten to disk\\b|\\bdelivered\\b',
);


export const hasLanded = (s, strict = false) => (strict ? LANDED_STRICT_RE : LANDED_RE).test(s);

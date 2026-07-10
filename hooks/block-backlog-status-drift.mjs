#!/usr/bin/env node
// PreToolUse (Edit|Write|MultiEdit) — ENFORCE BACKLOG.md single-status format AT WRITE TIME (fail-closed on bad status).
//
// WHY THIS EXISTS (root cause of recurring board-format drift):
//   the Stop-time drift backstop only WARNS at turn-end, AFTER the bad status is already written.
//   Per the ENFORCED>DETECTED>DECORATIVE principle, a warn-only gate lets drift through every time
//   an ad-hoc status is invented (e.g. [MERGED-DoD-PENDING] / [DATA-PENDING-REPUBLISH]).
//   This hook DENIES the Edit/Write itself, so a non-whitelist `### [STATUS]` can never land.
//
// Scope: ANY project's ACTIVE `.claude/BACKLOG.md` (path-generic). BACKLOG-archive*.md legitimately
// keeps [DONE] cards (DoD-gated below). Covers Edit (new_string), Write (content), MultiEdit
// (edits[].new_string). Fail-OPEN on parse error — a guard bug must NOT wedge every BACKLOG edit.
import fs from 'node:fs';

const WHITELIST = ['QUEUED', 'IN-DEV', 'REVIEW', 'BLOCKED', 'USER-GATED'];

// (B) BACKLOG-archive DoD-gate: a `### ` archive header signalling the DoD is NOT done must not pass.
// A DoD-VERIFIED / DoD-met / "#11-exception SATISFIED" / DONE+LIVE-verified header contains none of
// these → it passes.
const DOD_PENDING = [
  /DoD[^\n]{0,40}pending/i,                                // "DoD pending LEAD admin-walk", "DoD post-tick verify PENDING"
  /pending[^\n]{0,22}(verif|walk|playwright|republish)/i,  // "verify pending", "pending …Playwright"
  /\bverify\s+pending\b/i,
  /待[^\n。]{0,18}(验|重发|walk|playwright|republish)/i,    // Chinese: "待 … 验 / 重发 / Playwright"
  /DoD\s*(?:未|没)\s*(?:过|验)/,                            // "DoD 未过" / "DoD 没验"
];
// (B) POSITIVE DoD proof — an archived DONE card must AFFIRM DoD met, not merely omit "pending".
// (Closing the blocklist hole: a card that says NOTHING about DoD used to pass.)
const DOD_VERIFIED = [
  /DoD[-\s]?VERIFIED/i,
  /DoD[-\s]?met\b/i,
  /DoD[-\s]*(?:✅|pass|done|过|已验|通过|完成)/i,
  /\bLIVE[-\s]?(?:verified|confirmed)\b/i,
  /\bDONE\s*\+\s*LIVE/i,
  /\bTRIAGE[-\s]?COMPLETE\b/i,
  /#?\s*11[-\s]?exception/i,
];
// no-DoD-NEEDED categories — these legitimately archive WITHOUT a DoD (abandoned / phantom / dup, not "done").
const NO_DOD_NEEDED = [
  /\b(?:WONTFIX|FAKE|STALE|PHANTOM|DUPLICATE|DUPE|SUPERSEDED|DROPPED)\b/i,
  /USER[-\s]?DROPPED/i,
  /(?:不修|撤回|已撤|废弃|重复|并入|合并入|超出范围)/,
  /(?:无需|不需要?)\s*DoD/i,
  /\bNO[-\s]?DOD(?:-NEEDED)?\b/i,
  /DoD[-\s]?N\/A/i,
];

try {
  const input = JSON.parse(fs.readFileSync(0, 'utf8'));
  const ti = input.tool_input || {};
  const fp = String(ti.file_path || '').replace(/\\/g, '/');

  // (A) the ACTIVE board BACKLOG.md — status-whitelist; (B) BACKLOG-archive*.md — DoD-before-archive gate.
  const isActive = /\/\.claude\/BACKLOG\.md$/i.test(fp);
  const isArchive = /\/\.claude\/BACKLOG-archive[^/]*\.md$/i.test(fp);
  if (!isActive && !isArchive) process.exit(0);

  // gather all new content this tool call would write
  const chunks = [];
  if (ti.new_string !== undefined) chunks.push(String(ti.new_string));
  if (ti.content !== undefined) chunks.push(String(ti.content));
  if (Array.isArray(ti.edits)) for (const e of ti.edits) if (e && e.new_string !== undefined) chunks.push(String(e.new_string));
  const newc = chunks.join('\n');
  if (!newc) process.exit(0);

  // (A0) CARD-HEADER DEMOTE antipattern: an Edit whose old_string is a `### [STATUS]` card header
  // AND whose new_string STRIPS the `### ` prefix (demoting it to a plain line) while keeping the
  // card body/badge silently UNREGISTERS the card — every `^### `-keyed check (and
  // block-backlog-archive-residue) goes blind to the header-less orphan. Fires on the ACTIVE board
  // only, BEFORE the `### `-header extraction below (a demoted card has NO `### ` header in
  // new_string, so it would slip past the headers.length===0 early-exit).
  if (isActive) {
    const pairs = [];
    if (ti.old_string !== undefined && ti.new_string !== undefined) pairs.push({ old: String(ti.old_string), nu: String(ti.new_string) });
    if (Array.isArray(ti.edits)) for (const e of ti.edits) if (e && e.old_string !== undefined && e.new_string !== undefined) pairs.push({ old: String(e.old_string), nu: String(e.new_string) });
    for (const { old, nu } of pairs) {
      const oldFirst = (old.split('\n')[0] || '').trim();
      const newFirst = (nu.split('\n')[0] || '').trim();
      if (!/^###\s+\[[A-Z-]+\]/.test(oldFirst)) continue;               // old wasn't a card header
      if (/^###\s/.test(newFirst)) continue;                            // new keeps SOME `### ` header
      if (!nu.trim()) continue;                                         // pure delete → fine
      const keepsBody = /(?:^|\n)\s*-\s*(?:aliases|problem|fix|log):/.test(nu);   // English kit board uses ASCII ':'
      const looksLikeBadge = /^(?:\s*[✅❌🚫]|\s*MERGED\s+#|\s*DONE\b|\s*ARCHIVED\b|\s*PHANTOM\b)/i.test(newFirst);
      if (!(keepsBody || looksLikeBadge)) continue;
      process.stdout.write(JSON.stringify({
        hookSpecificOutput: {
          hookEventName: 'PreToolUse',
          permissionDecision: 'deny',
          permissionDecisionReason:
            `card-header DEMOTE antipattern: the Edit strips the \`### [STATUS]\` header off card "${oldFirst.slice(0, 60)}…" and replaces it with a non-\`### \` line ("${newFirst.slice(0, 60)}…") while keeping the card body/badge. That silently unregisters the card — the header-extraction checks (and block-backlog-archive-residue) all key on \`### \` headers and go BLIND to a header-less orphan. Correct archive flow: CUT the ENTIRE card block (header + body) OUT of the active board, then INSERT it INTO the archive ledger with a proper \`### [DONE] <slug> — PR #<N> MERGED @<sha>\` header + the full log tail. If pruning a phantom, do the same with a PHANTOM/exception note.`,
        },
      }));
      process.exit(0);
    }
  }

  // ANY `### ` card header in the new content.
  const headers = newc.split('\n').filter((l) => /^###\s+\S/.test(l));
  if (headers.length === 0) process.exit(0);

  let reason = null;
  if (isActive) {
    // (A) active board: bracketed STATUS → whitelist-check; bare badge (### ✅ / ### DONE / ### MERGED, NO [..]) → always deny.
    // (A bare-badge done-marker `### ✅ R-foo` would otherwise slip past a bracket-only check.)
    const bad = headers.filter((l) => {
      const m = l.match(/^###\s+\[([^\]]+)\]/);
      if (m) return !WHITELIST.includes(m[1]); // bracketed status: deny unless whitelisted
      return true;                             // no [..] bracket (bare ✅/DONE/MERGED badge): done cards belong in BACKLOG-archive.md
    });
    if (bad.length === 0) process.exit(0);
    reason =
      `BLOCKED (BACKLOG.md single-status format, fail-closed): this Edit/Write introduces ${bad.length} ` +
      `non-whitelisted ### [STATUS] header(s). STATUS must be one of {${WHITELIST.join(', ')}}. ` +
      `Rule: after merge + DoD, move the WHOLE card to BACKLOG-archive.md (the active board forbids ` +
      `[DONE]/✅/MERGED badges). Keep an unverified DoD at [REVIEW]; gate an external/republish dep with ` +
      `[BLOCKED] — do not invent ad-hoc statuses like [MERGED-DoD-PENDING] / [DATA-PENDING-REPUBLISH]. ` +
      `Offending header(s): ${bad.slice(0, 3).map((s) => s.trim()).join(' || ')}`;
  } else {
    // (B) archive DoD-gate: ALLOWLIST over the whole card BLOCK — a card moved INTO the archive must
    // POSITIVELY affirm DoD met OR be a no-DoD-needed category. A card that says NOTHING about DoD
    // (the old blocklist's hole — only "pending" was caught) OR still reads "DoD pending / verify
    // pending" is NOT a success → deny. Evaluate the DoD verdict from the HEADER line (archive
    // convention: `### ✅ <name> · … — <verdict>` carries the verdict inline), NOT the whole block —
    // a historical "DoD pending(LEAD)" step in a card's log body must not override a header that now
    // reads DoD-VERIFIED.
    // ANCHOR-EXCLUSION (rule-8: judge the ACTION, not incidental payload text): an Edit that INSERTS a
    // new card uses a neighbouring PRE-EXISTING card's header line as its old_string/new_string
    // positioning anchor. That anchor header is NOT a card archived by THIS edit, but it appears in
    // new_string -- and if the anchor TRUNCATED the header (dropping its "ARCHIVED / DoD-VERIFIED" tail)
    // this gate would misread it as a brand-new DoD-less card and deny the whole write, naming the WRONG
    // card. A header line that ALSO appears byte-identically in old_string is a positioning anchor ->
    // exclude it. A genuinely-new archived card can never be in old_string, so the gate's teeth are
    // unchanged for real archives.
    const anchorHeaders = new Set();
    const collectOld = (s) => String(s).split('\n').forEach((l) => { if (/^###\s+\S/.test(l)) anchorHeaders.add(l.trim()); });
    if (ti.old_string !== undefined) collectOld(ti.old_string);
    if (Array.isArray(ti.edits)) for (const e of ti.edits) if (e && e.old_string !== undefined) collectOld(e.old_string);
    const newHeaders = headers.filter((h) => !anchorHeaders.has(h.trim()));
    const bad = newHeaders.filter((h) => {
      if (NO_DOD_NEEDED.some((re) => re.test(h))) return false; // WONTFIX/FAKE/STALE/PHANTOM/… or no-DoD → exempt
      if (DOD_PENDING.some((re) => re.test(h))) return true;    // header says pending → not done (override)
      return !DOD_VERIFIED.some((re) => re.test(h));            // verified→ok; neither verified nor exempt→the HOLE→deny
    });
    if (bad.length === 0) process.exit(0);
    const pend = bad.some((h) => DOD_PENDING.some((re) => re.test(h)));
    reason =
      `BLOCKED (BACKLOG-archive DoD-gate, fail-closed): ${bad.length} card(s) moved into the archive but ` +
      `DoD is NOT proven. Archiving means success, and success means the DoD was verified first-hand. ` +
      `The card block must carry positive DoD evidence (DoD-VERIFIED / DoD-met / LIVE-verified|confirmed / ` +
      `DONE+LIVE / TRIAGE-COMPLETE / #11-exception), or be a no-DoD category ` +
      `(WONTFIX/FAKE/STALE/PHANTOM/DUPLICATE/SUPERSEDED/USER-DROPPED, or an explicit "no DoD needed"). ` +
      (pend
        ? `Detected "DoD pending / verify pending" = the DoD explicitly didn't pass → verify it before archiving. `
        : `Detected NO DoD statement at all (the old blocklist only caught explicit "pending") → a bare ` +
          `MERGED is not enough to archive; add DoD-verification evidence, or keep it on the active board at ` +
          `[REVIEW]/[BLOCKED] until verified. `) +
      `Offending card(s): ${bad.slice(0, 3).map((b) => b.split('\n')[0].trim().slice(0, 60)).join(' || ')}`;
  }

  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason: reason,
    },
  }));
  process.exit(0);
} catch {
  process.exit(0); // fail-open: never wedge BACKLOG edits on a guard bug
}

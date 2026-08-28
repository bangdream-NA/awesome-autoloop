#!/usr/bin/env node
import fs from 'node:fs';

const WHITELIST = ['QUEUED', 'IN-DEV', 'REVIEW', 'BLOCKED', 'USER-GATED'];

const DOD_PENDING = [
  /DoD[^\n]{0,40}pending/i,
  /pending[^\n]{0,22}(verif|walk|playwright|republish)/i,
  /\bverify\s+pending\b/i,
];
const DOD_VERIFIED = [
  /DoD[-\s]?VERIFIED/i,
  /DoD[-\s]?met\b/i,
  /DoD[-\s]*(?:✅|pass|done)/i,
  /\bLIVE[-\s]?(?:verified|confirmed)\b/i,
  /\bDONE\s*\+\s*LIVE/i,
  /\bTRIAGE[-\s]?COMPLETE\b/i,
  /#?\s*11[-\s]?exception/i,
];
const NO_DOD_NEEDED = [
  /\b(?:WONTFIX|FAKE|STALE|PHANTOM|DUPLICATE|DUPE|SUPERSEDED|DROPPED)\b/i,
  /USER[-\s]?DROPPED/i,
  /\bNO[-\s]?DOD(?:-NEEDED)?\b/i,
  /DoD[-\s]?N\/A/i,
];

try {
  const input = JSON.parse(fs.readFileSync(0, 'utf8'));
  const ti = input.tool_input || {};
  const fp = String(ti.file_path || '').replace(/\\/g, '/');

  const isActive = /\/\.claude\/BACKLOG\.md$/i.test(fp);
  const isArchive = /\/\.claude\/BACKLOG-archive[^/]*\.md$/i.test(fp);
  if (!isActive && !isArchive) process.exit(0);

  const chunks = [];
  if (ti.new_string !== undefined) chunks.push(String(ti.new_string));
  if (ti.content !== undefined) chunks.push(String(ti.content));
  if (Array.isArray(ti.edits)) for (const e of ti.edits) if (e && e.new_string !== undefined) chunks.push(String(e.new_string));
  const newc = chunks.join('\n');
  if (!newc) process.exit(0);

  if (isActive) {
    const pairs = [];
    if (ti.old_string !== undefined && ti.new_string !== undefined) pairs.push({ old: String(ti.old_string), nu: String(ti.new_string) });
    if (Array.isArray(ti.edits)) for (const e of ti.edits) if (e && e.old_string !== undefined && e.new_string !== undefined) pairs.push({ old: String(e.old_string), nu: String(e.new_string) });
    for (const { old, nu } of pairs) {
      const oldFirst = (old.split('\n')[0] || '').trim();
      const newFirst = (nu.split('\n')[0] || '').trim();
      if (!/^###\s+\[[A-Z-]+\]/.test(oldFirst)) continue;
      if (/^###\s/.test(newFirst)) continue;
      if (!nu.trim()) continue;
      const keepsBody = /(?:^|\n)\s*-\s*(?:aliases|problem|fix|log):/.test(nu);
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

  const headers = newc.split('\n').filter((l) => /^###\s+\S/.test(l));
  if (headers.length === 0) process.exit(0);

  let reason = null;
  if (isActive) {
    const bad = headers.filter((l) => {
      const m = l.match(/^###\s+\[([^\]]+)\]/);
      if (m) return !WHITELIST.includes(m[1]);
      return true;
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
    const anchorHeaders = new Set();
    const collectOld = (s) => String(s).split('\n').forEach((l) => { if (/^###\s+\S/.test(l)) anchorHeaders.add(l.trim()); });
    if (ti.old_string !== undefined) collectOld(ti.old_string);
    if (Array.isArray(ti.edits)) for (const e of ti.edits) if (e && e.old_string !== undefined) collectOld(e.old_string);
    const newHeaders = headers.filter((h) => !anchorHeaders.has(h.trim()));
    const bad = newHeaders.filter((h) => {
      if (NO_DOD_NEEDED.some((re) => re.test(h))) return false;
      if (DOD_PENDING.some((re) => re.test(h))) return true;
      return !DOD_VERIFIED.some((re) => re.test(h));
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
  process.exit(0);
}

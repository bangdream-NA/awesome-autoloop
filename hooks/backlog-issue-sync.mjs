#!/usr/bin/env node
import { readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { archiveTextFor } from "./lib/backlog-grammar.mjs";
import { autoLogOnDeny } from './lib/log-denial.mjs';
autoLogOnDeny('backlog-issue-sync');

const BACKLOG = process.env.AAL_BACKLOG;
const REPO = process.env.AAL_REPO;
const APPLY = process.argv.includes("--apply");
if (!BACKLOG || !REPO) {
  console.error("need AAL_BACKLOG=<path to BACKLOG.md> and AAL_REPO=<owner/name>");
  process.exit(2);
}

if (process.env.AAL_PUBLIC_REPO && new RegExp('(^|/)' + process.env.AAL_PUBLIC_REPO.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '$', 'i').test(REPO)) {
  console.error(`🚫 REFUSED: AAL_REPO=${REPO} is the PUBLIC issue-only repo.`);
  console.error(`   Board cards are internal material by definition (VPS paths, admin/elevated-session`);
  console.error(`   mechanics, unfixed vulnerabilities). A public repository carries no internal material.`);
  console.error(`   Point AAL_REPO at the PRIVATE code repository, not the public issue-only mirror.`);
  process.exit(2);
}

const LEAK = [
  /\/etc\/[a-z0-9-]*\/(?:secrets?|credentials?)\b/i, /\bssh\b/i, /\bscp\b/i,
  /PGPASSWORD|AUTH_SECRET|ADMIN_RELAY_TOKEN|_TOKEN\b|_PASSWORD\b|session-token/i,
  /elevated-session/i, /\/srv\//i, /sudo -u postgres/i,
  /\b(?:CVE|vulnerabilit(?:y|ies)|unpatched|unfixed|security)\b/i,
];
const leaks = (t) => LEAK.filter((re) => re.test(t)).map((re) => String(re));

const text = readFileSync(BACKLOG, "utf8");
const lines = text.split(/\r?\n/);
const cards = [];
for (let i = 0; i < lines.length; i++) {
  const m = lines[i].match(/^###\s+\[([A-Z-]+)\]\s+(\S+)\s*(.*)$/);
  if (!m) continue;
  let end = lines.length;
  for (let j = i + 1; j < lines.length; j++) if (/^###\s+\[/.test(lines[j])) { end = j; break; }
  const block = lines.slice(i, end).join("\n");
  const pr = (block.match(/^\s*-?\s*problem:\s*(.+)$/m) || [])[1] || m[3];
  cards.push({
    status: m[1],
    name: m[2],
    header: m[3],
    block,
    line: i + 1,
    issue: (block.match(/^\s*-?\s*issue:\s*#(\d+)\s*$/m) || [])[1] || null,
    gated: /\[gate\s*=/.test(m[3]),
    prio: (m[3].match(/\bP([0-3])\b/) || [])[1] || "3",
    summary: (pr || "").replace(/\*\*|`|\[\[|\]\]/g, "").replace(/\s+/g, " ").trim().slice(0, 300),
  });
}

const active = cards.filter((c) => !/^ARCHIVED/.test(c.status));
const plan = [];
for (const c of active) {
  const found = leaks(c.block);
  const body = [
    `**Canonical record: \`.claude/BACKLOG.md\` — this issue is a generated MIRROR.**`,
    `Edits here are overwritten on the next sync; change the board instead.`,
    ``,
    found.length
      ? `_Body withheld: this card mentions operational detail (${found.length} pattern hit(s)). Read the board._`
      : c.summary || '_(no problem line on the card)_',
    ``,
    `status: \`${c.status}\`${c.gated ? " · gated" : ""} · priority: P${c.prio}`,
  ].join("\n");
  plan.push({ c, action: c.issue ? `UPDATE #${c.issue}` : "CREATE", body, target: REPO });
}

console.log(`backlog-issue-sync ${APPLY ? "(APPLY)" : "(dry run — nothing will be written)"}`);
console.log(`board: ${BACKLOG}\nrepo:  ${REPO}\ncards: ${cards.length} total, ${active.length} active\n`);
for (const p of plan) {
  console.log(`${p.action.padEnd(12)} ${p.c.name}  [${p.c.status}] P${p.c.prio}${p.why ? `\n   ⚠️ ${p.why}` : ""}`);
}
const creates = plan.filter((p) => p.action === "CREATE").length;
const refused = 0;
console.log(`\n${creates} to create · ${plan.length - creates - refused} to update · ${refused} refused`);

if (!APPLY) {
  console.log(`\nNothing was written. Re-run with --apply once the plan looks right.`);
  console.log(`NOTE: creating ${creates} issues also writes an \`issue: #N\` line back into each card —`);
  console.log(`that line is what makes the next run an UPDATE instead of a duplicate CREATE.`);
  process.exit(0);
}

const { createHash } = await import("node:crypto");
const { writeFileSync: wf, existsSync: ex } = await import("node:fs");
const STATE = `${process.env.CLAUDE_CONFIG_DIR || (process.env.HOME || process.env.USERPROFILE) + '/.claude'}/.backlog-issue-sync-state.json`;
let cache = {};
try { if (ex(STATE)) cache = JSON.parse(readFileSync(STATE, "utf8")); } catch { cache = {}; }
const hashOf = (p) => createHash("sha1").update(`${p.c.name} [P${p.c.prio}]\n${p.body}`).digest("hex");

const gh = (args) => execFileSync("gh", args, { encoding: "utf8" }).trim();
let out = text;
let skipped = 0;
for (const p of plan) {
  if (p.action !== "CREATE" && cache[p.c.name] === hashOf(p)) { skipped++; continue; }
  try {
    if (p.action === "CREATE") {
      const url = gh(["issue", "create", "-R", REPO, "-t", `${p.c.name} [P${p.c.prio}]`, "-b", p.body]);
      const n = (url.match(/\/(\d+)\s*$/) || [])[1];
      if (!n) { console.error(`  ! could not parse issue number from: ${url}`); continue; }
      const hdr = p.c.block.split("\n")[0];
      out = out.replace(hdr, `${hdr}\n- issue: #${n}`);
      console.log(`  created #${n}  ${p.c.name}`);
    } else {
      const n = p.c.issue;
      gh(["issue", "edit", n, "-R", REPO, "-t", `${p.c.name} [P${p.c.prio}]`, "-b", p.body]);
      console.log(`  updated #${n}  ${p.c.name}`);
    }
    cache[p.c.name] = hashOf(p);
  } catch (e) {
    console.error(`  ! ${p.c.name}: ${String(e.message).split("\n")[0]}`);
  }
}
try { wf(STATE, JSON.stringify(cache, null, 1), "utf8"); } catch {  }
if (skipped) console.log(`${skipped} unchanged (hash cache) — no API call`);
if (out !== text) {
  const { writeFileSync } = await import("node:fs");
  writeFileSync(BACKLOG, out, "utf8");
  console.log("wrote issue: refs back into the board");
}

try {
  const archText = archiveTextFor(BACKLOG);
  if (archText) {
    const archRefs = [...archText.matchAll(/^\s*-?\s*issue:\s*#(\d+)\s*$/gm)]
      .map((m) => m[1]);
    if (archRefs.length) {
      const open = new Set(
        gh(["issue", "list", "-R", REPO, "--state", "open", "--limit", "200", "--json", "number", "-q", ".[].number"])
          .split(/\r?\n/).filter(Boolean),
      );
      for (const n of archRefs) {
        if (!open.has(n)) continue;
        try {
          gh(["issue", "close", n, "-R", REPO, "-c", "Card archived on the board (canonical record: `.claude/BACKLOG-archive.md`) — closed by backlog-issue-sync."]);
          console.log(`  closed #${n} (card archived)`);
        } catch (e) { console.error(`  ! close #${n}: ${String(e.message).split("\n")[0]}`); }
      }
    }
  }
} catch (e) { console.error(`  ! archive-close pass: ${String(e.message).split("\n")[0]}`); }

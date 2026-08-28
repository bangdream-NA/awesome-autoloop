#!/usr/bin/env node
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const BACKLOG = process.env.AAL_BACKLOG || join(process.env.CLAUDE_CONFIG_DIR || join(homedir(), ".claude"), "BACKLOG.md");
const STATUS_WL = ["QUEUED", "IN-DEV", "REVIEW", "BLOCKED", "USER-GATED"];
const REQUIRED_FIELDS = ["aliases", "problem", "fix", "log"];

function read(f) { try { return readFileSync(f, "utf8"); } catch { return null; } }

const text = read(BACKLOG);
if (text === null) {
  console.error(`board-sop: cannot read ${BACKLOG} (set AAL_BACKLOG to your board path).`);
  process.exit(0);
}

const lines = text.split(/\r?\n/);
const findings = [];

let i = 0;
while (i < lines.length) {
  const m = lines[i].match(/^###\s+\[([A-Z-]+)\]\s+(.+)$/);
  if (!m) { i++; continue; }
  const status = m[1];
  const title = m[2].trim();
  const headerLine = i + 1;

  if (!STATUS_WL.includes(status)) {
    findings.push(`HARD  L${headerLine}: status [${status}] not in ${STATUS_WL.join("/")} — "${title}"`);
  }

  const body = [];
  let j = i + 1;
  for (; j < lines.length; j++) {
    if (/^#{2,3}\s/.test(lines[j])) break;
    body.push(lines[j]);
  }
  const bodyText = body.join("\n");
  for (const f of REQUIRED_FIELDS) {
    const re = new RegExp(`^\\s*-\\s*${f}\\s*:`, "m");
    if (!re.test(bodyText)) {
      findings.push(`DEBT  L${headerLine}: card "${title}" missing required field "- ${f}:"`);
    }
  }
  i = j;
}

const hard = findings.filter((f) => f.startsWith("HARD"));
console.log(`board-sop :: ${BACKLOG}`);
console.log(`cards checked, ${findings.length} finding(s):`);
for (const f of findings) console.log("  " + f);
if (findings.length === 0) console.log("  (none — board is clean)");

process.exit(hard.length > 0 ? 1 : 0);

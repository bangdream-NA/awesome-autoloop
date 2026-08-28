#!/usr/bin/env node
import { readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { autoLogOnDeny } from './lib/log-denial.mjs';
import { projectPaths } from './lib/is-autoloop-lead.mjs';
autoLogOnDeny('require-ship-action-before-archive');

// The repository argument comes from AAL_REPO when an adopter sets it, and is OMITTED otherwise so
// that `gh` resolves the repository from the working directory the way it does on the command line.
// It used to be a literal placeholder, which cannot resolve anywhere: `gh` then failed on every call.
const GH_REPO_ARGS = process.env.AAL_REPO ? ["-R", process.env.AAL_REPO] : [];
const PROJECT = projectPaths()?.repo || "";
const OPS = `${PROJECT}/docs/runbooks/OPS.md`;

let payload = {};
try { payload = JSON.parse(readFileSync(0, "utf8") || "{}"); } catch { process.exit(0); }

const tool = payload.tool_name || "";
const inp = payload.tool_input || {};
const path = String(inp.file_path || inp.notebook_path || "");
if (!/BACKLOG-archive[^/\\]*\.md$/i.test(path)) process.exit(0);
const content = String(inp.content ?? inp.new_string ?? "");
if (!content) process.exit(0);

let rows = [];
try {
  const ops = readFileSync(OPS, "utf8");
  const sec = ops.split(/^## §1/m)[1] || "";
  rows = sec.split(/\r?\n/)
    .filter((l) => /^\|/.test(l) && !/^\|\s*-+/.test(l) && !/Change touches/i.test(l))
    .map((l) => l.split("|").map((c) => c.trim()).filter(Boolean))
    .filter((c) => c.length >= 3)
    .map(([touches, action, channel]) => ({
      globs: [...touches.matchAll(/`([^`]+)`/g)].map((m) => m[1]),
      action: action.replace(/\*\*/g, ""),
      manual: /manual/i.test(channel),
    }));
} catch { process.exit(0); }
if (!rows.length) process.exit(0);

const prs = [...content.matchAll(/(?:MERGED\s*#|PR\s*#|pr#)(\d{2,5})/gi)].map((m) => m[1]);
if (!prs.length) process.exit(0);
if (/(^|\s)ship:\s*\S/m.test(content)) process.exit(0);

const needed = new Map();
let ghFailed = null;
for (const pr of prs) {
  let files = [];
  try {
    const out = execFileSync("gh", ["pr", "view", pr, ...GH_REPO_ARGS, "--json", "files", "-q", ".files[].path"], { encoding: "utf8" });
    files = out.split(/\r?\n/).filter(Boolean);
  } catch (e) { ghFailed = `#${pr}: ${String(e.message).split("\n")[0]}`; continue; }
  if (!files.length) { ghFailed = `#${pr}: gh returned an EMPTY file list — treated as unknown, not as "touched nothing"`; continue; }
  for (const r of rows) {
    if (!r.manual) continue;
    for (const g of r.globs) {
      const re = new RegExp("^" + g.replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*\*/g, "«").replace(/\*/g, "[^/]*").replace(/«/g, ".*"));
      if (files.some((f) => re.test(f))) needed.set(r.action, g);
    }
  }
}

if (!needed.size && !ghFailed) process.exit(0);

const lines = [...needed].map(([a, g]) => `  · ${a}   (matched \`${g}\`)`).join("\n");
const reason =
  'BLOCKED: SHIP-ACTION GATE — this card is being archived for PR ' +
  prs.map((p) => `#${p}`).join(", ") +
  (needed.size
    ? `, whose changed files require a MANUAL ship action that nothing here records:\n${lines}\n\n`
    : "") +
  (ghFailed ? `⚠️ could not resolve changed files (${ghFailed}) — failing CLOSED, because an empty answer is not evidence of "nothing to ship".\n\n` : "") +
  "Merged is not shipped. Four times this week a wave was merged, marked done, and never reached " +
  "the box — most recently #984, whose DoD was walked against a build that did not contain it.\n\n" +
  "FIX: run the ship action, then record it on the card as a `ship:` line WITH first-hand evidence " +
  "(deploy → the run that printed all 8 phases + verify-state no drift; republish → the partition's own " +
  "curl'd timestamp; auto channel → the push-event run's success in `gh run list`). " +
  "If it genuinely does not need one, write `ship: N/A — <why>` and re-run. " +
  "The requirement comes from docs/runbooks/OPS.md §1, which this gate parses live rather than duplicating.";

process.stdout.write(JSON.stringify({
  hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: reason },
}));

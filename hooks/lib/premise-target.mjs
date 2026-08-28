#!/usr/bin/env node
import { readFileSync } from "node:fs";
import { jsonlPlanVerdict } from "./plan-verdict.mjs";

function readMaybe(p) {
  if (!p) return "";
  try { return readFileSync(p, "utf8"); } catch { return ""; }
}
const lc = (s) => String(s).toLowerCase();
const segs = (w) => String(w).split("-").filter(Boolean);

function conservativeForms(wave) {
  const forms = new Set([lc(wave)]);
  const s = segs(wave);
  if (s.length >= 6) {
    const stem = s.slice(0, s.length - 1).join("-");
    if (segs(stem).length >= 5 && stem.length >= 20) forms.add(lc(stem));
  }
  return forms;
}

function backlogAliases(backlogText, target) {
  if (!backlogText) return new Set();
  const t = lc(target);
  const lines = backlogText.split(/\r?\n/);
  const out = new Set();
  for (let i = 0; i < lines.length; i++) {
    const h = lines[i].match(/^#{2,4}\s+(?:\[[^\]]*\]\s*)?([A-Za-z0-9][\w-]*)/);
    if (!h) continue;
    let alias = "";
    for (let j = i + 1; j < lines.length && !/^#{2,4}\s/.test(lines[j]); j++) {
      const a = lines[j].match(/^\s*-\s*aliases\s*:\s*(.+)$/);
      if (a) { alias = a[1]; break; }
    }
    const headerSlug = lc(h[1]);
    const aliasSlugs = alias
      ? alias.split(',').map((x) => lc(x.trim())).filter(Boolean)
      : [];
    if (headerSlug === t || aliasSlugs.includes(t) || headerSlug.includes(t) || aliasSlugs.some((x) => x.includes(t))) {
      out.add(headerSlug);
      aliasSlugs.forEach((x) => out.add(x));
    }
  }
  return out;
}

function resolveTarget(ti) {
  const prompt = String(ti.prompt || "");
  const name = String(ti.name || "");
  const anchor = prompt.match(/for wave\s+\*\*([^*\n]+)\*\*/i);
  if (anchor) return anchor[1].trim();
  const blob = JSON.stringify(ti);
  const toks = blob.match(/(?<![a-z0-9])(?:wave-[a-z0-9-]+|r-[a-z0-9][a-z0-9-]+)(?![a-z0-9])/gi) || [];
  if (toks.length) return toks.slice().sort((a, b) => b.length - a.length)[0];
  const nm = name.match(/^dev-(.+)$/i);
  if (nm) return nm[1].trim();
  return null;
}

function main() {
  let raw = "";
  try { raw = readFileSync(0, "utf8"); } catch {  }
  let parsed;
  try { parsed = JSON.parse(raw); } catch { process.stdout.write("NOWAVE"); return; }
  const ti = parsed.tool_input || parsed;

  const target = resolveTarget(ti);
  if (!target) { process.stdout.write("NOWAVE"); return; }

  // CLAUDE_PROJECT_DIR/.claude. A rerouted project with NO plan-reviews ledger
  const bm = String(ti.prompt || "").match(/((?:[A-Za-z]:[\/\\]|\/)[^\n`'"]*?\.claude)[\/\\]BACKLOG\.md/i);
  const projDir = bm ? bm[1].replace(/\\/g, "/") : null;
  const fallbackDir = process.env.CLAUDE_PROJECT_DIR ? process.env.CLAUDE_PROJECT_DIR + "/.claude" : null;
  const prPath = process.env.AAL_PLAN_REVIEWS || process.argv[2] || (projDir ? projDir + "/plan-reviews.md" : (fallbackDir ? fallbackDir + "/plan-reviews.md" : null));
  const blPath = process.env.AAL_BACKLOG   || process.argv[3] || (projDir ? projDir + "/BACKLOG.md"      : (fallbackDir ? fallbackDir + "/BACKLOG.md"      : null));
  const jsonlPath = process.env.AAL_REVIEWS_JSONL
    || (projDir ? projDir + "/reviews/index.jsonl"
       : (fallbackDir ? fallbackDir + "/reviews/index.jsonl" : null));

  const forms = conservativeForms(target);
  backlogAliases(readMaybe(blPath), target).forEach((a) => {
    if (segs(a).length >= 3 && a.length >= 10) forms.add(a);
  });
  const keys = [...forms];

  if (jsonlPath) {
    const jv = jsonlPlanVerdict(jsonlPath, keys);
    if (jv === "approved") { process.stdout.write("OK"); return; }
    if (jv === "rejected") { process.stdout.write("NOVERDICT\t" + target); return; }
  }
  const pr = lc(readMaybe(prPath));
  if (!pr) { process.stdout.write("NOVERDICT\t" + target); return; }
  for (const form of keys) {
    if (pr.includes(form)) { process.stdout.write("OK"); return; }
  }
  process.stdout.write("NOVERDICT\t" + target);
}
main();

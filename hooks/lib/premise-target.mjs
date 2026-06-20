#!/usr/bin/env node
// Resolve the TARGET wave of a developer Agent dispatch + check it has a logged
// plan-review verdict. Used by require-premise-verified-before-dev.sh.
//
// DESIGN (death-constraint: false-ALLOW is worse than false-BLOCK):
//  1. TARGET wave is resolved from EXPLICIT fields, not "any candidate":
//       a. prompt anchor  `…for wave **<WAVE>**`  (canonical, primary)
//       b. word-boundary R-/wave- tokens, longest (fallback — the boundary
//          prevents a short wave token matching a digit-suffix substring inside
//          an unrelated word)
//       c. name field `dev-<wave>` (last resort)
//     No target identifiable → NOWAVE → caller DENIES (fail-closed).
//  2. Verdict presence is checked ONLY for the resolved target's own identity
//     forms — {canonical} ∪ {its BACKLOG card aliases} ∪ {one conservative
//     trailing-segment stem} — NEVER for an unrelated wave that the prompt
//     merely mentions. A short/loose stem is rejected to avoid matching a
//     DIFFERENT wave's verdict in the shared ledger (cross-wave collision =
//     the over-allow this gate must not do).
//
// Output (stdout): "OK" (allow) | "NOVERDICT\t<wave>" | "NOWAVE".
// Anything else / any throw → caller treats as DENY (fail-closed).
//
// Args:  argv[2] = plan-reviews.md path   argv[3] = BACKLOG.md path
// Env override (tests):  AAL_PLAN_REVIEWS, AAL_BACKLOG  (take precedence over args)
import { readFileSync } from "node:fs";

function readMaybe(p) {
  if (!p) return "";
  try { return readFileSync(p, "utf8"); } catch { return ""; }
}
const lc = (s) => String(s).toLowerCase();
const segs = (w) => String(w).split("-").filter(Boolean);

// One conservative stem: drop AT MOST one trailing segment, and only when the
// remainder stays specific (≥5 segments AND ≥20 chars). Keeps a long, specific
// wave key but never degrades to a short prefix that would collide.
function conservativeForms(wave) {
  const forms = new Set([lc(wave)]);
  const s = segs(wave);
  if (s.length >= 6) {
    const stem = s.slice(0, s.length - 1).join("-");
    if (segs(stem).length >= 5 && stem.length >= 20) forms.add(lc(stem));
  }
  return forms;
}

// Harvest the BACKLOG card aliases for a resolved target. A card is a `### …`
// header; its `- aliases:` (or legacy `- 别名:`) line lists comma-separated alias
// slugs. We match the card whose header OR alias line contains the target
// (case-insensitive), then return {header slug} ∪ {alias slugs} for that ONE card.
function backlogAliases(backlogText, target) {
  if (!backlogText) return new Set();
  const t = lc(target);
  const lines = backlogText.split(/\r?\n/);
  const out = new Set();
  for (let i = 0; i < lines.length; i++) {
    const h = lines[i].match(/^#{2,4}\s+(?:\[[^\]]*\]\s*)?([A-Za-z0-9][\w-]*)/);
    if (!h) continue;
    // gather this card's block until the next header
    let alias = "";
    for (let j = i + 1; j < lines.length && !/^#{2,4}\s/.test(lines[j]); j++) {
      const a = lines[j].match(/^\s*-\s*(?:aliases|别名)\s*[:：]\s*(.+)$/);
      if (a) { alias = a[1]; break; }
    }
    const headerSlug = lc(h[1]);
    const aliasSlugs = alias
      ? alias.split(/[,，]/).map((x) => lc(x.trim())).filter(Boolean)
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
  // (a) anchor — canonical, primary
  const anchor = prompt.match(/for wave\s+\*\*([^*\n]+)\*\*/i);
  if (anchor) return anchor[1].trim();
  // (b) word-boundary R-/wave- tokens (non-alnum boundaries kill a short token
  //     matching a digit-suffix substring of an unrelated word), pick the
  //     longest/most-specific.
  const blob = JSON.stringify(ti);
  const toks = blob.match(/(?<![a-z0-9])(?:wave-[a-z0-9-]+|r-[a-z0-9][a-z0-9-]+)(?![a-z0-9])/gi) || [];
  if (toks.length) return toks.slice().sort((a, b) => b.length - a.length)[0];
  // (c) name `dev-<wave>` last resort
  const nm = name.match(/^dev-(.+)$/i);
  if (nm) return nm[1].trim();
  return null;
}

function main() {
  let raw = "";
  try { raw = readFileSync(0, "utf8"); } catch { /* no stdin */ }
  let parsed;
  try { parsed = JSON.parse(raw); } catch { process.stdout.write("NOWAVE"); return; }
  const ti = parsed.tool_input || parsed;

  const target = resolveTarget(ti);
  if (!target) { process.stdout.write("NOWAVE"); return; }

  // Per-project ledger reroute: each dispatch cites its OWN project board's
  // absolute path. The FIRST `X:/…/.claude/BACKLOG.md` in the prompt selects that
  // project's plan-reviews + board. With no path in the prompt, fall back to
  // CLAUDE_PROJECT_DIR/.claude. A rerouted project with NO plan-reviews ledger
  // still fails CLOSED (readMaybe("")→NOVERDICT), which is correct for a
  // death-constraint.
  // NOTE: a Windows-drive path in the prompt (e.g. `<DRIVE>:/…/.claude/BACKLOG.md`)
  // is taken verbatim — these are JS string literals read by node directly, never
  // round-tripped through shell argv, so no MSYS drive-letter rewriting applies.
  const bm = String(ti.prompt || "").match(/([A-Za-z]:[\/\\][^\n`'"]*?\.claude)[\/\\]BACKLOG\.md/i);
  const projDir = bm ? bm[1].replace(/\\/g, "/") : null;
  const fallbackDir = process.env.CLAUDE_PROJECT_DIR ? process.env.CLAUDE_PROJECT_DIR + "/.claude" : null;
  const prPath = process.env.AAL_PLAN_REVIEWS || process.argv[2] || (projDir ? projDir + "/plan-reviews.md" : (fallbackDir ? fallbackDir + "/plan-reviews.md" : null));
  const blPath = process.env.AAL_BACKLOG   || process.argv[3] || (projDir ? projDir + "/BACKLOG.md"      : (fallbackDir ? fallbackDir + "/BACKLOG.md"      : null));
  const pr = lc(readMaybe(prPath));
  if (!pr) { process.stdout.write("NOVERDICT\t" + target); return; }

  const forms = conservativeForms(target);
  backlogAliases(readMaybe(blPath), target).forEach((a) => {
    // only trust an alias specific enough to not cross-collide
    if (segs(a).length >= 3 && a.length >= 10) forms.add(a);
  });

  for (const form of forms) {
    if (pr.includes(form)) { process.stdout.write("OK"); return; }
  }
  process.stdout.write("NOVERDICT\t" + target);
}
main();

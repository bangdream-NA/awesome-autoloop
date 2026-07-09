// plan-verdict.mjs — shared jsonl-first plan-review-verdict resolver for the architect gate
// (backlog-sop-validate.mjs) AND the developer gate (premise-target.mjs). ONE lookup so the two
// gates cannot drift on wave-matching / verdict classification (that drift IS the BLOCKER-1 class).
// Reads .claude/reviews/index.jsonl (the per-project machine-authoritative store). Mirrors
// require-pr-green's jsonl-first tri-state: 'approved' | 'rejected' | 'none' (none → caller falls
// through to the plan-reviews.md monolith legacy path). Newline-safe + parse-guarded (a fused /
// non-newline-terminated / garbled line is skipped, never a silent wrong verdict). MAIN-repo
// resolution stays with the CALLER (the two gates resolve their project dir differently by design).
import { readFileSync } from "node:fs";

const lc = (s) => String(s).toLowerCase();
const segs = (w) => String(w).split("-").filter(Boolean);
// Suffix-tolerant slug compat (verbatim-aligned with backlog-sop-validate.mjs `waveCompat`): exact,
// or one is a hyphen-suffix EXTENSION of the other, floored at 3 segments (accepts -r2/-phase2/-dev
// drift, rejects a true sibling). The SAME predicate for both gates = no wave-match drift.
export function waveCompat(a, b) {
  a = lc(a); b = lc(b);
  if (a === b) return true;
  const [s, l] = a.length <= b.length ? [a, b] : [b, a];
  return l.startsWith(s + "-") && segs(s).length >= 3;
}
// Classify a jsonl verdict token (mirror of lib/verdict.sh classify_jsonl_verdict): exact APPROVED
// allows; the reject zoo denies; APPROVED_WITH_* / unknown → null (fall through).
function classify(v) {
  switch (String(v || "").toUpperCase()) {
    case "APPROVED": return "approved";
    case "CHANGES_REQUESTED": case "CHANGES-REQUESTED":
    case "CHANGES_REQUIRED": case "CHANGES-REQUIRED":
    case "NEEDS_FIXES": case "NEEDS-FIXES":
    case "NEEDS_REVISION": case "NEEDS-REVISION":
    case "WONTFIX": case "REJECTED": return "rejected";
    default: return null; // APPROVED_WITH_* / unknown → fall through
  }
}
// jsonlPlanVerdict(jsonlPath, keys) -> 'approved' | 'rejected' | 'none'
//   jsonlPath : absolute path to <project>/.claude/reviews/index.jsonl
//   keys      : the caller's resolved wave-identity forms (normalized slugs) — {wave} ∪ aliases ∪ stem
// The LAST plan-review record (mode A, plan field waveCompat-matches ANY key) wins (final round
// supersedes). No matching record → 'none'.
export function jsonlPlanVerdict(jsonlPath, keys) {
  let text = "";
  try { text = readFileSync(jsonlPath, "utf8"); } catch { return "none"; }
  let last = "none";
  for (const line of text.split(/\r?\n/)) {
    const t = line.trim();
    if (!t) continue;
    let r; try { r = JSON.parse(t); } catch { continue; } // fused/garbled line skipped
    if (String(r.mode || "").toUpperCase() !== "A") continue; // plan review only
    const plan = r.plan;
    if (!plan) continue;
    if (!keys.some((k) => waveCompat(k, plan))) continue;
    const c = classify(r.verdict);
    if (c) last = c; // APPROVED_WITH_*/unknown (null) leaves `last` unchanged
  }
  return last;
}

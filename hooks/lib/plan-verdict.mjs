import { readFileSync } from "node:fs";

const lc = (s) => String(s).toLowerCase();
const segs = (w) => String(w).split("-").filter(Boolean);
export function waveCompat(a, b) {
  a = lc(a); b = lc(b);
  if (a === b) return true;
  const [s, l] = a.length <= b.length ? [a, b] : [b, a];
  return l.startsWith(s + "-") && segs(s).length >= 3;
}
function classify(v) {
  switch (String(v || "").toUpperCase()) {
    case "APPROVED": return "approved";
    case "CHANGES_REQUESTED": case "CHANGES-REQUESTED":
    case "CHANGES_REQUIRED": case "CHANGES-REQUIRED":
    case "NEEDS_FIXES": case "NEEDS-FIXES":
    case "NEEDS_REVISION": case "NEEDS-REVISION":
    case "WONTFIX": case "REJECTED": return "rejected";
    default: return null;
  }
}
export function jsonlPlanVerdict(jsonlPath, keys) {
  let text = "";
  try { text = readFileSync(jsonlPath, "utf8"); } catch { return "none"; }
  let last = "none";
  for (const line of text.split(/\r?\n/)) {
    const t = line.trim();
    if (!t) continue;
    let r; try { r = JSON.parse(t); } catch { continue; }
    if (String(r.mode || "").toUpperCase() !== "A") continue;
    const plan = r.plan;
    if (!plan) continue;
    if (!keys.some((k) => waveCompat(k, plan))) continue;
    const c = classify(r.verdict);
    if (c) last = c;
  }
  return last;
}

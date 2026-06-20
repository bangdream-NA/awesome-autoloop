---
name: hygiene-report
description: Repo debt / readability snapshot for the current git repo — largest source files, files over a line threshold, TODO/FIXME hotspots, 30-day churn, and a lightweight hygiene score. Run periodically or per N PRs for visibility on where rot accumulates (NOT a gate). Stack-agnostic.
---

# hygiene-report

Run from the repo root and report the findings:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/hygiene-report/report.sh" [line_threshold]   # default threshold 800
```

It scans TRACKED source files (excludes node_modules/dist/.next/coverage, `data*/` dirs, `docs/`, lockfiles, and data/binary extensions — so data fixtures + historical specs don't drown out code debt) and prints:
1. **Largest files** (top 15) — readability hotspots.
2. **Files over the threshold** (default 800 lines) — split-candidates.
3. **TODO/FIXME/HACK/XXX hotspots** (top files + total).
4. **Fastest-changing files** (last 30 days) — where churn concentrates.
5. **Hygiene score** /100 — `-3` per oversized file, `-1` per 10 markers (advisory).

How to use the output:
- This is **observability, not enforcement** — the point is to SEE rot early, not block on it. Don't auto-fix everything it lists.
- An oversized file with a clear reason (an archived/disabled script, a generated token file, a big i18n test) is fine — judge per file.
- A file that's BOTH large AND high-churn is the strongest split/refactor candidate — flag those for a follow-up.
- Pair with `claude-doctor` (harness health) — this is repo-code health.

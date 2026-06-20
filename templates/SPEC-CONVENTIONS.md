# SPEC-CONVENTIONS

> Lightweight conventions that downstream Architect specs in `docs/product-specs/`
> MUST follow. Each rule is greppable — Reviewer Z-axis can enforce without a
> markdown parser or CI gate. Surfaced after a spec shipped a table-vs-summary
> count drift (the summary line and the table it summarized diverged silently).

---

## §1 Purpose

Architect specs frequently summarize a markdown table with a one-line count
("Distribution: 21 public-read · 1 public-write · 5 admin-read · ..."). When the
table is edited but the summary line is not (or vice versa), the spec diverges
from itself silently; readers — and downstream phase agents — can't tell which
is truth. (e.g. a Distribution summary line totals N, but the table above it was
later edited to a different distribution.) This document collects lightweight
conventions that catch this class of drift via grep, without requiring CI gates
or markdown parsers.

---

## §2 Convention: count-summary recount marker

**Rule**: every count-summary line within a spec MUST be followed (within 5
lines, no blank lines between) by an HTML comment of exactly this form:

```html
<!-- recount-from-table-above -->
```

"Count-summary" = any line that totals or distributes counts derived from a
markdown table immediately above (typically containing words like
"Distribution:", "Total:", "Final tally:", or numeric breakdowns separated by
` · ` / `+` / `,`).

**Marker form rationale**:
- HTML comment (not prose `(derived from table above)`): invisible in rendered
  Markdown, greppable via `rg "recount-from-table-above"`, no false-positive on
  prose with similar phrasing.
- Exact literal string (no parametric form): keeps Reviewer Z-grep one-line and
  stable. No `<!-- recount-from-table-above:N -->` or other variants.
- Within 5 lines: tolerates blank-line + sub-bullet patterns; readers still see
  the marker near the claim.

---

## §3 Reviewer enforcement

Reviewer Z-axis pipeline-ergonomics audit (non-blocking) adds: grep for
count-summary patterns in touched specs of the PR. If a summary line is
detected WITHOUT a marker within 5 lines after, emit a MEDIUM advisory pointing
at the spec + line. Does NOT block APPROVED.

Reviewer grep recipe (committed to `.claude/code-reviews.md` template):

```bash
rg -n "Distribution:|Final tally:|Total:" $(git diff main --name-only | rg '^docs/product-specs/.*\.md$')
# For each hit, verify recount-from-table-above marker within 5 lines after.
```

---

## §4 Deferred / future extensions

Not in scope for this convention: markdown-lint CI gate (rejected as too brittle
on freeform tables); heuristic auto-recount (rejected — >50% false-positive).
Future Architect waves may revisit if the drift class re-emerges ≥3 times.

---

## §5 Example: retro-application

**Before** (a spec's mapping section, pre-marker):

```markdown
Final mapping. Format: `<METHOD> <path>` → `<tier>` (file:line).
Distribution: 21 public-read · 1 public-write · 5 admin-read · 22 admin-write · 3 scraper-ingest · 1 metrics · 0 none.

Note: `/health`, `/metrics` are NOT in this table ...
```

**After** (retro-marker added):

```markdown
Final mapping. Format: `<METHOD> <path>` → `<tier>` (file:line).
Distribution: 21 public-read · 1 public-write · 5 admin-read · 22 admin-write · 3 scraper-ingest · 1 metrics · 0 none.
<!-- recount-from-table-above -->

Note: `/health`, `/metrics` are NOT in this table ...
```

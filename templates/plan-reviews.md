# Plan reviews — FROZEN LEGACY

> **FROZEN LEGACY — do NOT append here.** Reviewers now write each verdict as a per-verdict file
> under `reviews/` (`<wave>-planrev-r<N>.md`) + a machine-authoritative line in
> `reviews/index.jsonl`. The architect dispatch gate (backlog-sop-validate.mjs, --mode pre-dispatch)
> reads `reviews/index.jsonl` **FIRST**; this monolith is a legacy fallback only (still gate-read for
> pre-migration adopters, but never a new append target). A self-written BACKLOG "PLAN_APPROVED" line
> does NOT satisfy the gate.
>
> Legacy block format (the gate's fallback greps the heading shape + the verdict line):

## Plan review: <wave> @<plan-sha>
- **Reviewer**: plan-reviewer (Mode A)
- **Mode**: A (plan-doc review — not a PR/code review)
- **Verdict**: APPROVED | APPROVED-WITH-NOTES | NEEDS_REVISION
- **Notes**: <one line per point; address every numbered item before re-dispatch>

<!-- This is an inert seed. The heading wave-token "<wave>" is a literal placeholder and can
     never resolve to a real card slug, so this block is ignored by the gate. Replace the whole
     block with a real review (real wave slug + real plan SHA) on your first plan review. -->

# Code reviews — FROZEN LEGACY

> **FROZEN LEGACY — do NOT append here.** Reviewers now write each verdict as a per-verdict file
> `reviews/pr<N>-r<round>.md` (`## PR #<N>` heading + `VERDICT: APPROVED @<HEAD-short-sha>` +
> `Reviewer-type: code-reviewer`) + a machine-authoritative line in `reviews/index.jsonl`, which the
> merge gates read FIRST. This monolith is a legacy fallback only (still gate-read for pre-migration
> adopters, never a new append target).
> This file MUST STAY PRESENT — it is also an autoloop activation marker; its presence enables the
> gates in this project.

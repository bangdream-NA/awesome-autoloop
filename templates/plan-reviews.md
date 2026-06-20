# Plan reviews

> Append one block per plan review here. The architect dispatch gate
> (backlog-sop-validate.mjs, --mode pre-dispatch) reads this file: it requires an APPROVED
> Mode-A verdict block whose heading wave-token matches the dispatched wave BEFORE it lets an
> architect run. This is the plan-reviewer's OWN artifact — a self-written BACKLOG "PLAN_APPROVED"
> line does NOT satisfy the gate.
>
> Block format (the gate greps the heading shape + the verdict line):

## Plan review: <wave> @<plan-sha>
- **Reviewer**: plan-reviewer (Mode A)
- **Mode**: A (plan-doc review — not a PR/code review)
- **Verdict**: APPROVED | APPROVED-WITH-NOTES | NEEDS_REVISION
- **Notes**: <one line per point; address every numbered item before re-dispatch>

<!-- This is an inert seed. The heading wave-token "<wave>" is a literal placeholder and can
     never resolve to a real card slug, so this block is ignored by the gate. Replace the whole
     block with a real review (real wave slug + real plan SHA) on your first plan review. -->

<!-- Runbook template — copy-on-demand. This file is NOT auto-seeded into your .claude/ by the
     installer (most projects have no prod-ops surface). Copy it to docs/runbooks/<op>.md when you
     have a server / deploy / data-pipeline operation worth documenting, then fill in each section.

     It pairs with the EXAMPLE gate require-runbook-before-server-op (examples/): if you mount that
     gate, it denies a prod operation unless your recent transcript shows you READ the matching
     runbook first. A runbook is the ground truth for BOTH the procedure AND its known failures —
     the gate exists so an operator can't reverse-engineer a live box with ad-hoc probes. -->

# Runbook: <operation name>

## Overview

<One paragraph: what this operation does, when you run it, and what it touches. Name the live
artifact it changes (a deployed service, a published shard, a DB row) so the reader knows the blast
radius before step 1.>

## Prerequisites

<Everything that must be true BEFORE step 1: required access (which host, which token), a clean
working tree, the right branch/checkout, any secret-injection mechanism (and how it is injected —
NEVER source a secrets file into your own shell; use the sanctioned unit/wrapper that extracts only
the vars it needs). List the exact env vars and where they come from.>

## Steps

<Numbered, copy-pasteable. Each step is one command or one decision. Annotate any step that mutates
the live artifact. Show the expected output of the make-or-break step so a reader can tell success
from a silent no-op.>

1. <command> — <what it does / expected output>
2. <command> — <…>

## Known footguns

<The failures that have actually bitten this operation. For each: the symptom, the root cause, and
what to do instead. This is the highest-value section — it is what turns a blind re-run into a
correct one. (Examples: a size-cap that silently SKIPS instead of failing; a path that diverges
between two checkouts; a glob that mtime-sorts an empty file as "newest".)>

## Rollback

<How to undo if a step fails midway. If the operation is not cleanly reversible, SAY SO and give the
safest recovery path (restore from backup, re-publish the prior shard, redeploy the prior tag).>

## Verification (Definition of Done)

<How to confirm the operation actually worked on the LIVE artifact — not "the command exited 0", but
the downstream effect: the page renders the new field (read a screenshot), the endpoint returns the
new value (curl it), the DB row updated (query it). CI-green / deploy-complete is necessary, NOT
sufficient.>

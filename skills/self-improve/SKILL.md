---
name: self-improve
description: Review the struggle log and recent session history to propose concrete self-improvements — new memories, rule additions, hooks, or CLAUDE.md hard rules. Triggers on "review struggle log", "self-improve", "what can we improve", "learn from mistakes". Proposes only; never auto-applies.
---

# Self-Improve

Use this skill to turn accumulated execution struggles into durable improvements. Run it
periodically (e.g. via `/loop` or a cron) or when the user asks to review the struggle log,
self-improve, or learn from mistakes.

This skill PROPOSES improvements for the user to approve — it NEVER auto-applies a change to
rules, hooks, memory, or CLAUDE.md.

## Steps

1. **Read the struggle log.** Open `<project>/.claude/struggle-log.md` (prefer the project copy;
   fall back to `~/.claude/struggle-log.md`). Also skim the recent session history for friction
   the log may not have captured yet. If the log is empty or absent, say so and stop.

   **Routing test (apply while mining the log):** the struggle-log records ONLY execution friction the
   agent ITSELF hit — 「伤到我的执行了?」→ struggle-log；「是要去修/建的东西?」→ BACKLOG card. A DISCOVERED bug
   or improvement idea (even one found while diagnosing another symptom) is a WORK ITEM for the board, not a
   log row. When you find a mis-filed work-item in the log, PROPOSE re-routing it onto a BACKLOG card
   (propose-never-apply) — do not silently move it.

1b. **Read the gate-denial log.** Open `<project>/.claude/.gate-denials` (and `.gate-denials.1` if a
   rotation exists). Each line is `<ts> | <hook> | <pattern-id> | <reason>`. Group by `(hook, pattern-id)`
   and count recurrence. This is the structured friction signal the harness already produces — the richest
   complement to the prose struggle-log. If the file is absent or empty, skip this and mine the log only.

2. **Identify RECURRING patterns.** A pattern is worth acting on when it is NOT a one-off:
   - the same `Category` appears 2+ times, OR
   - a `(hook, pattern-id)` group in `.gate-denials` recurs **3 or more times** (a footgun you keep
     hitting), OR
   - a `Lesson` was written but never acted on (no `→ rule/hook/memory` suffix on the row), OR
   - distinct rows share a root cause even under different categories.
   Ignore genuine one-offs — only durable, repeating friction earns a change. (Denial recurrence is
   counted over the un-rotated tail `.gate-denials` + `.gate-denials.1`, count-only, no time window;
   distinct pattern-ids from the same hook do NOT aggregate — the group key is the PAIR.)

3. **For each recurring pattern, propose EXACTLY ONE of:**
   - **a memory entry** — if it's a fact or preference to remember across sessions.
   - **a rule addition to `rules/common/`** — if it's a process discipline (the FEW rules the
     model wouldn't naturally follow).
   - **a new hook** — if it's an enforcement that should be automated (state the event/matcher
     and whether it fails closed or open).
   - **a CLAUDE.md addition** — if it's a hard rule that must override default behavior.
   Pick the lightest mechanism that actually prevents recurrence; prefer a rule/memory over a hook
   unless automated enforcement is the only thing that will hold.

4. **Present the proposals to the user for approval.** Show each as: the pattern (with the
   struggle-log rows that evidence it), the proposed change, where it lands, and the exact text to
   add. NEVER apply any change without explicit approval. If the user approves a subset, apply only
   those.

5. **Mark acted-on rows.** For each struggle-log row whose pattern produced an approved change,
   append a `→ rule` / `→ hook` / `→ memory` / `→ CLAUDE.md` suffix to that row's `Resolution`
   cell so it is not re-proposed on the next run.

6. **Record the run (cadence marker).** After presenting proposals (even if there were none), write the
   current epoch seconds to `<project>/.claude/.aal-state/self-improve-last-run` (create `.aal-state/` if
   needed). This is the DURABLE, session-INDEPENDENT cadence marker the SessionStart preflight reads to
   nudge ">24h since last self-improve" — it survives a session rotation (a cron would not). Do NOT key it
   by session; do NOT put it under a temp dir.

## Guardrails

- Propose, never auto-apply. A self-modifying loop that edits its own rules/hooks without a human
  in the loop is a footgun — the approval gate is the whole point.
- Keep proposals surgical. One change per pattern; do not bundle unrelated cleanups.
- A rule/hook you propose must answer "how is it observed/enforced?" — a rule with no observability
  is decorative. Prefer ENFORCED (a hook that fails closed) > DETECTED (a warn) > DECORATIVE (prose).

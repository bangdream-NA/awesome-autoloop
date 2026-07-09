# Autoloop op-log — <project>

> One row per ledger-worthy action. The merge gate (require-oplog-row-for-this-merge.sh) searches
> ALL `autoloop-log-*.md` in the project `.claude/` (grep-ALL) for a row citing the merging PR's
> literal #<number> BEFORE `gh pr merge <N>` is allowed — the row may live in ANY session's ledger;
> the Stop nudge (oplog-turn-reminder.sh) catches between-merge ops.
>
> **Per-session naming.** Under the per-session model each session appends to its OWN
> `autoloop-log-<YYYY-MM-DD>-<sid8>.md` (`sid8` = the first 8 alphanumeric chars of the session id),
> so two concurrent sessions never corrupt one shared ledger. **Two-class rotation**
> (oplog-turn-reminder.sh): a session rotates ONLY its own `sid8`-suffixed ledger to a same-`sid8`
> dated successor when it crosses the ~250KB Read-tool ceiling, and legacy un-suffixed ledgers keep
> the existing filename-digit rotation — it NEVER rotates another session's `sid8` ledger.
>
> This file's name (autoloop-log-TEMPLATE.md) is matched by the gate's `autoloop-log-*.md` glob, so
> the op-log convention is ACTIVE from install. Append your rows below. (Rename to a per-session
> `autoloop-log-<YYYY-MM-DD>-<sid8>.md`, or a plain `autoloop-log-<YYYY-MM-DD>.md`; any
> `autoloop-log-*.md` name works — the grep-ALL gate finds the row wherever it lands.)
>
> Row format:

## <date> · <wave> · <ACTION>
- proof: <what proves it — PR #<N>, sha, curl/screenshot, log line>
- next: <the next action; omit only when status is DONE/ARCHIVED>

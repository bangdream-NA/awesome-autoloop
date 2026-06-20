# Autoloop op-log — <project>

> One row per ledger-worthy action. The merge gate (require-oplog-row-for-this-merge.sh) requires
> the LATEST autoloop-log-*.md to contain a row citing the merging PR's literal #<number> BEFORE
> `gh pr merge <N>` is allowed; the Stop nudge (oplog-turn-reminder.sh) catches between-merge ops.
>
> This file's name (autoloop-log-TEMPLATE.md) is already matched by the gate's
> `ls -t autoloop-log-*.md` resolver, so the op-log convention is ACTIVE from install. Append your
> rows below. (Optionally rename to autoloop-log-<YYYY-MM-DD>.md and rotate per the ledger-size
> guidance; any autoloop-log-*.md name works.)
>
> Row format:

## <date> · <wave> · <ACTION>
- proof: <what proves it — PR #<N>, sha, curl/screenshot, log line>
- next: <the next action; omit only when status is DONE/ARCHIVED>

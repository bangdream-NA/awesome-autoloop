# Walk: <PR #N or wave> — <date>

> Post-merge DoD verification artifact. The dod-walk gates (check-unwalked-merges.sh etc.) look
> for a walks/*.md mentioning each merged PR# before letting the session end. Two valid forms:
>
> 1. UI / live-artifact PR — verify the deployed page/CLI/API first-hand and record it:
>    - **PR**: #<N>
>    - **Verified**: <what you opened / ran> — <what you observed (screenshot read, curl output, …)>
>    - **Result**: PASS | issues: <…>
>
> 2. Non-UI PR (installer/docs/skills/infra) — the gate accepts an explicit N/A line:
>    - `PR #<N>: non-UI (<reason>), walk N/A — DoD = <test/proof>`

PR #<N>: non-UI (installer/docs/skills), walk N/A — DoD = first-run test green

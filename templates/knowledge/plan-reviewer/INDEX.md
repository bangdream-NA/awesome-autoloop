# plan-reviewer — knowledge index

**Ships empty.** Lines are appended by the `plan-reviewer` agent as it writes files into this directory.

## Line format

```text
- [<file>](<file>) — <one line saying what it is for>
```

The one-line summary is what a future `plan-reviewer` reads to decide whether to open the file, so it
states the FINDING, not the topic.

## Scope

Only the `plan-reviewer` writes here. Everything a `plan-reviewer` may also read lives in
[../common/INDEX.md](../common/INDEX.md). File naming: `<topic>--<yyyymmdd>-<wave-slug>.md`.

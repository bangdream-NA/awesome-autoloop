# planner — knowledge index

**Ships empty.** Lines are appended by the `planner` agent as it writes files into this directory.

## Line format

```text
- [<file>](<file>) — <one line saying what it is for>
```

The one-line summary is what a future `planner` reads to decide whether to open the file, so it
states the FINDING, not the topic.

## Scope

Only the `planner` writes here. Everything a `planner` may also read lives in
[../common/INDEX.md](../common/INDEX.md). File naming: `<topic>--<yyyymmdd>-<wave-slug>.md`.

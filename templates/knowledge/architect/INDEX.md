# architect — knowledge index

**Ships empty.** Lines are appended by the `architect` agent as it writes files into this directory.

## Line format

```text
- [<file>](<file>) — <one line saying what it is for>
```

The one-line summary is what a future `architect` reads to decide whether to open the file, so it
states the FINDING, not the topic.

## Scope

Only the `architect` writes here. Everything a `architect` may also read lives in
[../common/INDEX.md](../common/INDEX.md). File naming: `<topic>--<yyyymmdd>-<wave-slug>.md`.

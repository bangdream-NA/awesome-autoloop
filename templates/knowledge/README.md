# The knowledge channel

A place for each pipeline role to write down what it learned, so the next agent of that role starts
where the last one stopped. It ships as a **convention** — the directory shape and the index format
— and nothing else. No entries ship: an entry is one machine's corpus, and corpus is exactly what
should not travel between projects.

## Shape

```text
knowledge/
├── README.md              this file — the contract
├── INDEX.md               the root index: format documentation only, never entries
├── common/INDEX.md        knowledge every role may read
├── planner/INDEX.md
├── plan-reviewer/INDEX.md
├── uiux-designer/INDEX.md
├── architect/INDEX.md
├── developer/INDEX.md
└── code-reviewer/INDEX.md
```

One directory per pipeline role, plus `common`. The role directories are the six agents in
`agents/`; if you add a role, add its directory and its `INDEX.md` in the same change.

## The read/write contract

- A role **reads** `knowledge/common/*` and its **own** role directory.
- A role **writes** only into its own role directory.
- Every new file gets **one line appended** to that directory's `INDEX.md`.
- A role never edits another role's directory, and never edits the **root** `INDEX.md`.

The `knowledge-role-isolation` hook enforces the write half. It denies a `Write`/`Edit` under
`knowledge/<role>/` when the acting agent is not that role, and it is a no-op outside an autoloop
project like every other gate here.

## The index line format

```text
- [<file>](<file>) — <one line saying what it is for>
```

One line per file, in the `INDEX.md` of the directory that holds the file. The one-line summary is
what a future agent reads to decide whether to open the file, so it describes the finding rather
than the topic: *"a bounded retry's elapsed lower bound is (n-1)×interval"* is useful,
*"notes about retries"* is not.

## What does NOT belong here

- Session state, hand-off notes, or anything that stops being true when the session ends.
- Secrets, tokens, or any credential value.
- Anything already stated in the project's own `CLAUDE.md` or rules — a second copy is a second
  thing to keep in step.
- Entries about one specific repository, in a directory that ships to every repository.

## Naming

`<topic>--<yyyymmdd>-<wave-slug>.md`. The date and the wave make a stale file identifiable without
opening it; the topic makes the filename its own index entry.

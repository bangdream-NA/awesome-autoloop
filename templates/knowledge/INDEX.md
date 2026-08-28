# Knowledge index

**This index ships EMPTY, and that is the design.** It documents the format; it never lists entries.
A populated root index is one machine's corpus, and corpus does not travel between projects.

Read the contract in [README.md](README.md) before writing anything here.

## Structure

- `common/` — knowledge every role may read.
- One directory per pipeline role: `architect/` · `code-reviewer/` · `developer/` · `plan-reviewer/` · `planner/` · `uiux-designer/`.

## Line format, in every directory index

```text
- [<file>](<file>) — <one line saying what it is for>
```

## Who writes where

A role reads `common/*` and its OWN directory, and writes only into its own directory, appending
one line to that directory's index per new file. No role edits another role's directory, and no
role edits THIS file.

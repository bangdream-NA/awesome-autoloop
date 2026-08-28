# Claiming absence · finding the owner · pinning a SHA · walk coverage

The four operations where a confident wrong answer is cheapest to produce. Each one turns a reading from YOUR side into a statement about the WORLD, and nothing in between is instrumented.

## 1. Before you write "there is none"

**A negative claim must be accompanied by a description of what its opposite would look like.** If you cannot say *"if this existed, I would see it here, in this shape"*, you have not earned the right to say it does not exist.

Corpora to sweep, by subject:

| the claim is about | search at least |
|---|---|
| whether a task board carries it | the active board **and every archive partition and detail partition** — glob them all, never count partitions by hand, never search only the active board |
| a credential, token, config or state | the config directory **including dotfiles**, the hook state directory, the environment, and any machine-side config path |
| whether a convention was deliberate | that wave family's own plan and architecture documents |
| whether a mechanism, error name or constant has an owner | **all** spec documents (not just the family you assume), every board partition, **every operations-log partition**, and `git log -S '<the line>' -- <file>` |
| whether this has been decided before | three corpora, all required: the board partitions · the spec documents · **the operations-log partitions**. The third is the one most often skipped and the one most often holding the answer — a task's BIRTH is recorded in the op-log, while the task itself may be archived under a name that shares no words with the symptom |
| the SCOPE of a mechanism | **the line that defines its scope** — the glob the sweep prints, the denominator the guard prints, the copy list the installer prints. Never its directory |

- A zero produced by searching only your own repository's docs and scripts is a property of your search, not of the world.
- If you cannot find the line that defines a mechanism's scope, **that absence is itself the finding** — write it up as a question, not as a premise.
- **A must-hit control guards the instrument, not the vocabulary.** It proves the token can match; it does not prove the token is the right one. Zero hits plus a working control usually means a third thing: **this corpus cannot contain the answer.**

## 2. Pinning down one sweep

Print the RAW, unclassified hit list and its count FIRST; then the classification table. `rows in the table == lines in the output` is checkable at a glance, while publishing only the classification lets a short enumeration stay invisible forever.

⚠️ Before any number goes into a rule or a verdict, ask: **did I measure it, or did my display stop there?** `head`, `tail`, `-n`, a trailing `| head -N` and every tool's default row limit are all triggers for that question.

## 3. Finding the owner

1. **`CANDIDATES:`** — list every filename the search returned, without pruning.
2. For each one you rule out, quote the sentence **from its own header that says what it judges**.

**If you cannot quote that sentence, you have not read it, and you may not rule it out.** The criterion is *what the file judges*, never *what it is called*.

## 4. Pinning a SHA — three legs, all printed

1. `git show --stat <sha>` — did that commit actually touch this document?
2. `git merge-base --is-ancestor <sha> HEAD` — is it on this branch?
3. `git log <sha>..HEAD -- <doc>` — **has anyone touched it since?**

A non-empty third leg means printing `git diff <sha> HEAD -- <doc>` line by line and saying whether the changes are formatting or meaning. If you cannot say, **the pin does not hold**.

📌 A token pins **the document**, never a task card, a ledger row or a PR description. A ledger line recording that someone once approved something does not tell you what they approved.

## 4b. Symptom to prior ruling: the key is the FILE PATH

Domain words, task slugs and wave names routinely share nothing with one another, while **every specification cites the files it rules on**. Search by path:

```sh
grep -rl '<file>' <specs-dir>/*.md          # who has ruled on this file
grep -rn '<file>' <board>*.md               # which task owns it (all partitions)
grep -rn '<file>' <op-log>*.md              # when its task was born, and who ruled
```

🔴 **Run all three, and do not demote the broadest predicate to the role of control.** Before writing "nobody has ruled on this", ask: **is my must-hit control closer to this thing's real name than my actual search term is?** If so, swap them and search again.

## 5. What a walk must cover

- **A user-facing walk covers**: the happy path · the empty state · zero data · loading · the error state · whether the primary action is obvious · whether the copy and spacing are readable.
- **Compare any new or changed visible surface against the existing design language**: glyphs, icons, geometry, colour, radii, borders, spacing. Read the message catalogue, the hardcoded strings in markup, the global stylesheet and the neighbouring components.
- **When a shared field, a canonical value, a bridge artifact or a published partition changes**: enumerate every downstream consumer, verify each one after publication, and run a duplication check on any aggregate view using the correct partition key.
- **Before opening a task from a screenshot, answer two questions**: is this surface locked or guarded by something (search the CI workflows for an end-to-end lane, the design document, the locked decisions)? And is this actually a different DOM (judge by the image's real pixels plus the device qualifiers read back in the SAME evaluation)?

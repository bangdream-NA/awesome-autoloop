# Writing a gate

Rules for authoring an enforcement hook, changing its denial text, or writing its fixture. Everything here is about the gate itself — the pipeline rules live in `pipeline-discipline.md`, the engineering rules in `principles.md`.

## 1. The must-red control comes first

**The first deliverable of a new gate is its must-red control, not its predicate.** Write the arm that proves the gate fires, watch it fail against the un-gated code, and only then write the code that makes it pass. A gate whose fixture was written after the fix is green because it was fitted to the fix.

- **Feed the must-red arm a PRODUCTION payload, not one you invented.** The payload includes the path, the tool name and the matcher, not just the content — a fixture with a real body and a convenient `file_path` tests a different function, and it passes *more* convincingly than one that is wholly fake.
- **Two things to check before you trust a red.** First, the decision CHANNEL: pass/fail may travel by exit code, by stdout JSON, or by stderr, and reading the wrong one is reading a constant. Second, the POSITIVE control: feed the fixture an input that must fail, and confirm it does.
- **When you fix an over-firing gate, do not swap a predicate that cannot fail for one that cannot pass.** Both are unfalsifiable; only the direction of the lie changes.

🔴 **That rule covers ADDITIONS. A subtraction is the opposite shape.** Adding an exclusion, tightening a predicate, silencing a class of warning, deleting an arm — the weight there sits on the **must-GREEN** arm, and you write that one first. Removing too much never turns a must-red red: a must-red asks "did the thing that should be caught get caught", while the failure mode of a subtraction is "something that should NOT have been caught was", which lives entirely in the must-red's blind spot.

**Ask, before writing the first arm: does this change make the gate say YES more often, or NO more often?** More "no" ⇒ write a must-still-fire arm first, and feed it the payload closest to the new exclusion boundary that ought *not* to be excluded.

## 2. Count the arms before you read the exit status

An arm that never ran and an arm that passed produce the same exit code and the same summary line.

- Each time you add an arm, confirm the ARM COUNT changed before you look at the result.
- Compute the summary from the results array; never hardcode the total.
- `if (capability exists) { assert } else { SKIP }` must `exit 1` in the else branch. **A skip that stays out of the denominator is counted as a pass.**

## 3. The predicate

- **Fail closed, and judge only the CURRENT action.** Never make the decision depend on a network call that can silently return empty.
- **Read intent from a structured anchor; never grep the whole command.** A command that merely *mentions* the thing being gated — in a commit message, a heredoc, an echo, a grep pattern — is not that action. Anchor on the command position, the tool name, or the parsed argument.
- **Include an arm where the trigger word appears as DATA and the gate must allow.**

## 4. The denial text

**It carries exactly two things: the token or format the gate accepts, and the command to run right now.**

The test for a sentence: *can it be rewritten as a command or a token?* If not, it does not belong in the denial.

- Rationale, history, verbatim quotations, incident narratives, dates and "from today onwards…" go in a SOURCE COMMENT, never in the text the operator reads.
- **Count the lines before you ship a denial: past about a dozen, it has not been edited down.** Cut in this order — the incident story, then the quotations, then dates and attributions, then "why this predicate", then the counter-examples.
- Changing the text does not require changing the predicate. **Changing the predicate requires the operator's authorisation.**
- Re-run the denial after editing it, and read what it actually printed.

## 5. Turning a ruling into a gate

- Put the deciding sentence **verbatim in the gate's source comment**, and list every constraint the implementation adds beyond it, each with its reason.
- 🔴 **Verbatim quotation belongs in the source comment and nowhere else.** A rules file, an agent definition and a denial message are all instructions addressed to someone else; provenance, dates and quotations do not belong in any of them. The test: *does the reader need to know who said it in order to act?* If not, it is provenance, not instruction.
- Do not invent a system-level label for one ruling. Quote it and date it, in the comment.
- A check: **if a rule makes its own sanctioned remedy impossible in some situation, that is an implementation bug, not strictness.**

## 6. Commands and alerts

- **A command whose success matters must not be piped**: `cmd > "$TMP/out" 2>&1; rc=$?`. Pipe only what you alone will read, and mark it. Judge file state with `test -f` / `[ -s ]` / a `--json` field, never with the exit code of a pipeline's last stage.
- **An alert that is correct but not currently actionable can neither be deleted nor printed every turn.** Register it — subject, reason, linked task — then stay silent on the registered ones and keep reporting new instances.

## 7. Is the gate actually mounted?

A hook can be mounted in more than one place: the user-level settings, the project-level settings, a dispatcher script, a delegate registry inside another hook, or a wrapper's own list.

**Search all of them, and pair a zero result with a must-hit control** — run the same search for a hook you know is mounted. If the control also returns zero, the corpus is wrong and the conclusion is not.

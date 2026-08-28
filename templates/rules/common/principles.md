# Principles

These are the few rules a capable model won't naturally follow. Everything else: use your judgment. Adapt the project-specific parts to your stack.

## Immutability
Create new objects, never mutate. Return a new copy with the changes.

## Pipeline
A 6-agent team via the Agent Teams feature — pass any `team_name` string in the `Agent()` call (there is no separate `TeamCreate` step; it was removed in Claude Code v2.1.178, which creates one implicit team per session). Planner -> Plan-reviewer -> UIUX-designer (UI waves only) -> Architect -> Developer -> Code-reviewer. The Developer writes code; the Reviewer verifies it. An Iteration Contract precedes coding. Dispatch each wave via `Agent({team_name, …})` + a full SendMessage brief; track waves on `{{BACKLOG_PATH}}`. NEVER use the harness TaskCreate/TaskList/TaskUpdate store — it is banned (ID collisions; the session dir and team dir never sync). SendMessage is the only dispatch + status + hand-off channel.

The full pipeline is REQUIRED for any fix that is site-wide (≥3 surfaces share the affected code), introduces a new component/token, changes a11y semantics or foundational structure, or needs cross-browser verification — even if the diff is tiny. Direct-dev (no pipeline) is allowed ONLY for a truly mechanical single-file one-line change with no new component/token/a11y. When in doubt, use the pipeline.

**User-provided verbatim copy is LOCKED INPUT — captured at intake, threaded every stage.** When the request contains specific COPY (a button label, empty-state / CTA wording, microcopy, legal text — any exact string the user wants shown), quote it VERBATIM into the plan and add an acceptance criterion that it ships EXACTLY as given; never generalize or paraphrase it. Paraphrasing user copy at planning is a stage-0 failure no downstream gate can recover — the later stages have nothing to compare against. Each stage re-checks shipped-string equals user-verbatim. The same applies to a user-provided DESIGN (a separated button vs an inline link, a layout): ship what they specified, not a generalization. (A paraphrased empty-state CTA once shipped as body text fused to an inline link, unreadable, because the exact copy was lost at planning and no stage had the original to compare against.)

Each pipeline stage owns a duty for this: **Planner** quotes the user's verbatim copy into the plan and names the empty / error / loading states as explicit acceptance criteria, not just the happy path; **Designer** designs those empty / error / loading states and renders a primary CTA as a real, separated button (not a bare inline link fused to body text); **Architect** locks the exact strings and the empty-state component shape into the spec, so they cannot degrade to a generic template; **Developer** ships the exact string and the designed empty-state (no generic substitution when specific copy was given); **Reviewer** greps the exact user-verbatim string in the diff (shipped equals given) and walks the empty / error / loading views, not only the populated one. A happy-path-only review is incomplete.

## Commit
Conventional format (`feat`/`fix`/`refactor`/`docs`/`test`/`chore`: description). No `Co-Authored-By`. No `.claude/` in git.

## Quality
TDD — write the test first. Edge tests are mandatory. If the project has an explicit coverage gate, respect it; otherwise ship with edge tests and don't chase an arbitrary %. A code-reviewer APPROVED verdict is required before shipping.

## Verification (cross-audit; trust no one)
Trust no verdict on its face — not a prior session's, not the user's premise, not your OWN pipeline/audit/reviewer agents. Independently re-verify every consequential claim against the LIVE artifact + logs, using tools (curl the live data, drive the live page / read its computed output, `git`/`gh`, read the source), BEFORE acting. A verdict never adversarially checked is UNVERIFIED; one that contradicts live data or user intent is REFUTED. Every pipeline agent must do this too — cite the live evidence, never an upstream assertion.

- **Web-verify external facts:** for any EXTERNAL fact or third-party datum (release dates, API status codes, library/tool behavior, an unfamiliar error), prefer a web search against the OFFICIAL source over trusting internal data or training memory. Cross-check even your own data against the official source when the check is cheap.

## Simplicity & surgical scope
Write the minimum code that solves THE problem; touch only what the request needs.
- No speculative features / abstractions / config / "flexibility" that wasn't asked for; no error-handling for impossible states. If 200 lines could be 50, rewrite. Self-check: "would a senior engineer call this overcomplicated?"
- Surgical edits: do NOT "improve"/refactor/reformat adjacent code that isn't broken; match the surrounding style even if you'd do it differently. Remove ONLY the imports/vars/functions YOUR change orphaned; pre-existing dead code → flag it for a follow-up, do NOT delete it in this PR. Every changed line should trace to the wave's stated scope.
- CAVEAT: "simplicity" applies to the CODE a wave ships — NOT to the process. The pipeline, the gates, premise-verify, RED→GREEN, and post-deploy DoD are heavyweight by design; do not "simplify" them away. And in a full-autonomous / autoloop posture, "stop and ask the user when uncertain" is REPLACED by "verify the premise live, then decide autonomously" — ask only for genuine user-decision items (irreversible actions, infrastructure, or user-provided copy), never as a default.

## Engineering
- **Fix bugs at the SOURCE layer:** trace to where the wrong value originates and fix it THERE — never ship an output-layer clamp/filter that masks wrong upstream data.
- **Hardcoded constants:** when fixing a hardcoded constant (colors/enums/canonical lists/regex), grep the WHOLE repo for parallel copies and fix/consolidate ALL of them before declaring done — an un-grepped duplicate is a regression timer. More generally, when a cross-cutting fix touches multiple checks or parallel copies (across files or runtimes), ENUMERATE the full affected set FIRST and verify every member — a too-narrow filter (e.g. one file extension) under-counts and leaves the rest as a regression timer (the classic three-then-four-then-six leaky-enumeration).
- **Entity merge / collapse / dedup is a user decision, never an architect default.** Any change that MERGES, COLLAPSES, UNIFIES, DEDUPES, or REDIRECTS distinct entities into one LOSES information if they are actually distinct. Before doing it, verify first-hand whether the entities have distinct real attributes (different times, dates, identities, or contents); if they do, the fix is per-entity, never a unify. Route the decision to the user rather than defaulting it — e.g. the separate days of a multi-day event, or two same-name-different-thing records, must stay distinct.
- **Background-loop timers:** call `.unref?.()` on every `setTimeout`/`setInterval` handle in long-lived modules so they don't block test exit / clean shutdown.

---

# Mechanisms and discriminators

The entries below are the ones where knowing the conclusion is not enough — you have to know the
mechanism, because their failure mode is *"every individual step was correct."* Imperative rules
live in `CLAUDE.md`; this file carries the machinery behind them.

## 1. A DoD with no SUBJECT chains compliant steps into a wrong result

A DoD defines **how to verify**, never **what to verify**. With the subject missing, "walk the DoD"
degrades into "measure everything measurable" ⇒ anything that cannot produce a reading counts as a
failure ⇒ every failure opens a remedy card ⇒ the remedy card has no subject either ⇒ the chain
feeds itself. **No single checkpoint catches it, because every step is compliant.**

- Discriminator: take the number in the card's problem statement and **re-measure it in production
  today**. It moved ⇒ VERIFIED; it did not ⇒ FAILED; **"I could not measure it" is neither**.
- For an arm that produces no reading, ask first: *"the action that would make it green — who
  authorised it?"* Nobody ⇒ retire the arm; do not go satisfy it.
- Instrument and reality disagreeing has three explanations: reality is wrong · the instrument is
  wrong · **the instrument asked the wrong question**. Jumping to "the instrument is wrong" is the
  most expensive default, because a wave that repairs an instrument changes zero production bytes
  and therefore can never visibly fail.
- Before measuring, state **which surface this card owns** — the one you are about to measure.
  A failure verdict produced by measuring the wrong surface reads *more* rigorous than the correct
  one.
- All remedy tracks closing is the trigger to **go back to the source card**, not to move forward.

## 2. "Nobody signed it" is not the same as "waiting for the user to sign it"

Ask: *"per this wave's own plan, whose baton is this step?"* If the answer is a pipeline role,
**dispatch that role**. Packaging an absent PIPELINE STEP as an absent USER DECISION makes every
option wrong — and the one the user most naturally picks ("you decide") is the worst of them: it
approves skipping the baton.

- Discriminator: does the string live in `<title>` / meta (invisible ⇒ SEO) or in `<h1>` / body
  (visible ⇒ UI, needs a designer)?
- `UNSIGNED` is a **state**, not an addressee: it says nobody signed, not who should.
- Before citing "the user has not ruled on it", prove they did not — the signed table is often
  already in the repo.
- A case-sensitive grep cannot support an absence claim (`designer` returning 0 while the truth was
  13 occurrences of `Designer`).

## 3. Swapping the tool also swaps away the gates mounted on the old tool

Discriminator: **after I changed tools, are the gates that were mounted on the old one still there?**

- The board guards mount on `PreToolUse` for `Write|Edit|MultiEdit` and nothing on `Bash`. Editing
  the board with a script bypasses that entire layer while producing a byte-identical result —
  **the failure mode is silent allow, with no symptom**.
- Correct shape: use Bash **read-only** to compute line numbers and confirm the anchor, then `Edit`
  to write. Use a **whole line** as `old_string` — a fragment gets read as a new prose line by the
  guard, and it locates less reliably.
- Same family: any "I bypassed the recommended path" optimisation deserves this question. Another
  form is treating a **sent** message as a completed handshake (sent ≠ delivered ≠ read ≠ approved).
- A gate being added later does not retire the discipline — the next spelling (perl / awk /
  `node -e`) bypasses it just as well. A gate only knows the shapes it has seen.

## 4. The measurement that argues a wave SHOULD open also contains the evidence it CANNOT ship

Reading an output with a question in mind shows you only the half you went looking for — once the
question has an answer, the reading stops.

- In the same turn you write down the reason to open a wave, ask: *"that same output which proved
  this is worth doing — what did it say about how the result reaches production?"*
- Signal: the reason for the wave has the shape "capability X structurally does not exist". A list
  saying *"you cannot do X"* is usually also saying *"you cannot do Y"*, and Y is often the delivery
  path.
- Once the limit is confirmed real, there is a second question: **who set it?** Scan two families —
  the card's own, and the one that **owns the constraint** (its slug has no literal overlap with the
  card's, so searching by slug cannot find it).
- Before opening the wave, read the operations log entry where this wave was born. You wrote it;
  you do not have to search for it.

## 5. Three categories that must not be mixed

app source → dispatch the developer · KNOWN server op → read the runbook and execute ·
NEW / complex / irreversible → PLAN first.

A new, complex or irreversible infrastructure change (a service's run identity · sudoers · a
systemd unit · ownership and permissions of a production secret · anything that can lock you out or
break the deploy path) **with no existing runbook** ⇒ that is a wave: plan + architecture + the
runbook the lead will execute + **a tested rollback**, and only then touch the server.

A card saying "the lead does not execute this alone / the user must rule" is a signal that **this is
a wave**, not a licence for the lead to improvise on the spot.

## 6. A must-RED control's condition gets supplied or destroyed by the environment that runs it

Discriminator: **is any condition the thing under test depends on something the RUNNING ENVIRONMENT
supplies or destroys for free?** The axes measured so far:

- **Corpus** — leave any dimension of the fixture to the environment and neither red nor green
  carries information (the board · the transcript · a state dir · the roster · the clock). The
  corpus is **code**, not files: running a regex over whole source files hits the old code quoted
  verbatim inside a fix comment.
- **Time** — a hard-coded timestamp crossing midnight turns the fixture into a genuinely different
  state; always generate relative to now at run time.
- **Host** — a condition like "the only pending handle in this process" is destroyed by the test
  runner's own IPC handle; it needs a child process.
- **Entry shape** — a top-level `await` and `.then(code => process.exit(code))` exit with different
  codes, so the "reproduction" reproduces a *different* failure while looking correct.
- **Payload** — the path, the tool name and the matcher are all payload, not just the content.
  Real content with a casually-filled `file_path` tests a different function, and **it goes green
  more convincingly than an all-false run**. Feed a production payload, not one you invented.

## 7. Find the owner before building the mechanism

Before writing any mechanism (a hook · a predicate · a function · a script · a counting rule), grep
for its owner. **Found one ⇒ import it / add to it.** Two mechanisms for one concept with no shared
predicate produce opposite verdicts while each half reads correct on its own.

- Discriminator: *"if these two ever disagree, which is right?"* No answer ⇒ they were always meant
  to be one.
- Auditing a number by re-implementing the function under test ⇒ **import the function under test**;
  if it is not exported, extract it from the file's bytes and print the transformation for review.
- The reverse direction: when more than one consumer reads a field, ask *"do they expect the same
  thing from this line?"* Different expectations ⇒ split the field, or write both meanings where the
  field is **produced**; do not rely on consumers to be compatible.
- The worst form is a **proxy metric**: whenever "recently touched" stands in for "the work got
  done", **any** action satisfies it — including the bookkeeping action itself. It fails silently
  and covers its own tracks.
- **"I know this rule" ≠ "I checked it at the moment I acted."** Hang the trigger on the **action**,
  not on memory: before writing a mechanism / predicate / constant / denial text, run one grep and
  paste the command. In a single day, three owners already existed and three fresh copies got
  written anyway.
- 🔴 **When a layer is split out of another, the sentence "always come back to this one filter"
  cannot reach it.** A dispatch filter can carry its own note — *"'I may not dispatch' has several
  sources and this layer knows only some of them; a new source must come back to this one filter"* —
  and hold for every case that stays **inside** that layer, then fail on the first case that lands in
  a layer **split out of it**: the new layer asks the same question (who owes the next baton) and
  inherits **not one** of the suppressions, so it names a card the dispatch gate is guaranteed to
  refuse, every round.
  ⇒ Discriminator: **"who else answers this same question?"** When you split or copy a decision,
  take the **suppression conditions** with it and make the two sites name each other; moving only
  the main logic creates a twin that is **semantically identical with an empty suppression set**.
  ⚠️ Its failure mode is **noise**, not a wrong answer ⇒ nothing goes red, people just learn to
  ignore that layer.

## 8. A few discriminators that read like decoration

- **A hand-written conclusion outlives the measurement it summarised.** Discriminator: *"would this
  line print unchanged if the fact were the opposite?"* Yes ⇒ it is decoration, and decoration gets
  read as evidence. Defences by strength: ① make the detector an **exported value**, not a sentence
  someone has to remember to update; ② let the condition actually take part in the computation
  rather than printing both cases identically; ③ for a document carrying status labels, grep the
  **whole label class** after any revision.
- **The most expensive instance is the "open question" on a card** — it does not merely go stale, it
  pushes you to do something already done. Discriminator, before opening a card / raising a question
  / naming a landing slot: **"if this had already been done, where would I see it?"** The answer must
  include **the archive** and `git log --all --grep`. The gap can be as small as one day: a card
  records the world at the moment it was born.
- **A reason for INACTION is the class of claim nobody ever checks.** Ask *"how many commands would
  it take to verify?"* One, and you did not run it ⇒ it is a guess. The alarm is **repetition**, not
  doubt — the third time one gate reports the same thing, ask *"under what condition is this
  predicate necessarily true?"*
- **Do the action the gate named; never a synonym** — the omitted half is systematically the
  **check** half (`git pull` = `fetch` + `merge`). A worktree's `origin/*` is a snapshot of the last
  fetch and is **byte-indistinguishable from a fresh one**. Before merging into a worktree, assert
  `git rev-parse HEAD == git rev-parse origin/<branch>`.
- **Store a ruling together with the question it answered**, and date it. Before citing it to close
  something, prove that something already existed when the ruling was made. Over-extending a "do not
  do X" silently kills work the user never refused, and nobody reopens it — **a ruling's own wording
  is its boundary**.
- When implementing a user lock, write the exact words into the **source comment**, and list every
  constraint the implementation **added** with its reason. Test: a rule that makes its own sanctioned
  remedy impossible is usually an implementation bug, not strictness.
- **A failure line in a tool result is not background.** When `error` / `failed` / a non-zero rc
  appears, deal with it before the next command, or write down why it does not affect the conclusion.
  First separate the kinds: the tool's own input validation failing (`String to replace not found`) ·
  a gate's refusal (carrying the gate name and a `FIX:`) · the command failing. **A refusal has a
  fingerprint; the one without a fingerprint is not a verdict** — reading "the tool did not run" as
  "the gate allowed it" builds every later step on a reading that does not exist.
- **Measuring the root cause is not the end.** In the turn you say "fix it", finish the **predicate ·
  the denial text · the fixture · the mounting**; do not ask for permission step by step. "I have
  diagnosed it, shall I fix it?" is the violation shape.
- 🔴 **The corpus list in a brief IS the agent's world boundary — the source you left out, it cannot
  structurally recover.** When dispatching a census or an ownership hunt, list them all: every board
  file · **every operations-log file** · the reviews directory including its jsonl index · the
  struggle log · every spec doc including archives · `git log --all --grep` and `-S`.
  ⚠️ **A ruling often survives only in the operations log** — a spoken "we are not doing that" never
  reaches the board on its own. Frame the question correctly too: not "is there a card for it", but
  **"does any corpus show this was ruled on — done, or explicitly declined?"**
  The second half, when reading the report: **read its "what I could not answer" section first, then
  decide which of its conclusions to act on** — a conclusion with a gap holds only inside the corpus
  it searched, and using it on the far side of the gap is an assertion **you** added.
- 🔴 **A failure that leaves no artifact never gets a mechanism built for it.** A red gate, red CI, a
  wrong number — all leave traces, so all get fixed; "searched the wrong corpus, took ten extra
  commands, found it in the end" **looks exactly like ordinary work**, and the cost lands only on
  your time. Discriminator: **will this failure turn anything red?** No ⇒ it belongs to the class you
  systematically under-build for.
  ⚠️ A successful detour **destroys the evidence it should have left** — each "found it in the end"
  makes that instance not count, so the reason never accumulates. Hang the trigger on **how many
  extra steps** it took: got there the long way ⇒ write the cost into the operations log that turn,
  instead of dropping it because you succeeded.
- **"Do we have a record of this?" gets answered "yes" almost every time — and that yes closes the
  question.** Discriminator: **"which corpus is it in, and how many steps to reach it?"** Three or
  more ⇒ what is missing is an **index**, not information; and an index adds no new information, so
  it never gets raised on the grounds of incompleteness.
- **To ask "is X inside this gate's scope", read the predicate or a fixture arm — never a prose
  `SCOPE:` line.** One file can carry a stale prose note, a correct side comment and a must-RED arm
  pinning it, and all three read equally authoritative.
- 🔴 **A reading that does not match expectation has two possible subjects: the world under test, or
  your command.** Before writing the difference up as a finding, measure it again on a different leg
  (follow / no-follow · GET / HEAD · another uid). **A different command ≠ a changed fact.** Before
  changing an expected value, prove the thing under test actually changed; otherwise you are writing
  the instrument's wrong answer into the spec.
- **A production expectation cannot be verified by an agent that may not touch the server.** Measure
  it yourself before dispatching, or mark it `UNMEASURED` in the plan; a reviewer writing "it returns
  X today" must carry the command and the reading in the same sentence.
- **A server operation has two runbooks: what to change, and how it is delivered.** People read the
  first one every time; the gate checks the first one too. Nothing asks about the second, so it is
  missing every time — and **the symptom appears on the other person's side** (you hand them a plan
  that cannot be executed on that machine) while your own side shows nothing. Discriminator:
  **"who types this command, and in which interface?"** If the answer is not "me over SSH", that
  interface has its own runbook — find it first.
- **A document that reads as complete stops anyone from asking whether there is a second one.** A
  pasteable block of commands is the strongest such signal: it looks like the whole story, so the
  question "does the delivery channel even exist" never gets raised.
- **A gate token says what THAT CARD is waiting for, not what YOU are waiting for.** The moment you
  write one, the card leaves your hands — that is the reason the token exists. Discriminator:
  **"does the event it waits for need me sitting here?"** No ⇒ move to the next piece of work this
  turn; if it needs watching, attach a background watcher rather than treating it as a stop.
- **Diagnosis is not disposition.** "This is drift class five" / "these two files overlap" is a
  reason to START, not to postpone. Discriminator: **is this sentence describing a problem, or an
  action?** Describing a problem ⇒ it is a task.
- **A lesson gets written in the shape of the story that taught it.** The story reads load-bearing
  because it is what convinced you — but the reader of a rule does not need convincing, they need to
  act. Discriminator: **is this sentence HOW TO DO IT, or WHY I BELIEVE IT?** The latter belongs in
  the rationale file. Same family as "answer the question first" — except an artifact outlives a
  reply, so the redundancy costs more here.

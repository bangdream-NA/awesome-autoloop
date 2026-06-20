---
name: project-profiler
description: Scan THIS project's checkout (manifests, CI, test runner, linter, deploy surface) and PROPOSE a tailored awesome-autoloop setup — gate-group selection, what the dod-walk live-verify means here, which templates/rules/<stack> scaffold to adopt, and example stack rules. Triggers on "profile this project", "project-profiler", "tailor the setup", "what gates fit here". PROPOSES only; never writes to your .claude/ without an explicit approval step.
---

# Project Profiler

Scan the user's actual checkout and PROPOSE a setup tailored to its stack. This skill is the
"install → tailored" step: the installer ships a generic setup; this reads the real project and
proposes how to specialize it. It PROPOSES — it writes NOTHING to the user's `.claude/` without an
explicit, per-run approval step (AC-2 / AC-13). A run with no approval mutates zero user files.

## Steps

1. **Detect the stack(s) — first-hand file reads, never guessed.** Read the manifests + CI + scripts
   that EXIST (don't assume):
   - Node/TypeScript: `package.json` (scripts.test / scripts.build / packageManager), lockfile
     (`pnpm-lock.yaml` / `package-lock.json` / `yarn.lock`), `tsconfig.json`.
   - Python: `pyproject.toml` / `setup.cfg` / `requirements.txt`, `pytest.ini` / `tox.ini`.
   - Kotlin/Android: `build.gradle(.kts)`, `settings.gradle(.kts)`, `gradle/`, `AndroidManifest.xml`.
   - Go: `go.mod`. Rust: `Cargo.toml`.
   - CI: `.github/workflows/*.yml`, `.gitlab-ci.yml`, `Makefile`/`Justfile`.
   - Deploy surface: Dockerfile, `wrangler.*`, `fly.toml`, `vercel.json`, `*.tf`, k8s manifests.
   Report the detected stack, its test runner, CI, and deploy surface — what you READ, with the file
   it came from. Only name a stack that has a shipped `templates/rules/<stack>/` scaffold (the
   profiler's match set — `node-ts`, `python`, `kotlin-android`). Other stacks → generic guidance.

2. **No recognized stack → degrade cleanly (AC-3).** If no known manifest is found (empty repo / an
   unknown stack), say "no single stack recognized → keep the generic rules; here's how to write your
   own stack rules" and propose NOTHING stack-specific. No crash, no mis-classification.

3. **Multi-stack / monorepo → report ALL (AC-4).** If 2+ stacks are detected (e.g. a Node workspace +
   an Android module), report every one and propose a scaffold per detected stack (or flag the
   ambiguity for the user to choose). Never silently pick one and hide the rest.

4. **Build the PROPOSAL (a report, never a write — AC-2).** Present:
   - **Proposed `AAL_GATES`** for this stack (e.g. deselect `merge-gates` if no GitHub-PR workflow is
     detected; keep all groups for a GitHub repo).
   - **What the dod-walk live-verify means HERE** (a real-browser walk for a web app; a built-binary
     run for a CLI; an API exercise for a library — inferred from the deploy surface).
   - **Which `templates/rules/<stack>/` scaffold to adopt**, read from
     `${CLAUDE_PLUGIN_ROOT}/templates/rules/<stack>/` (mounted, read-only), with 2-3 example rules
     quoted so the user sees what they'd get.
   - A **wave-naming suggestion** consistent with the user's history if a BACKLOG exists.

5. **Approval gate (AC-13).** Present the proposal and ASK. NEVER write to the user's `.claude/`
   without explicit approval. On approval: copy the chosen scaffold + apply the `AAL_GATES` edit the
   user OK'd, then remove `.claude/.pending-profile`. On decline: leave everything untouched (the
   marker stays; the user can dismiss by deleting `.claude/.pending-profile`).

6. **Non-interactive / CI (edge).** If invoked where no input can be gathered, produce the report and
   STOP — do not hang waiting for approval. The apply/approve step is a separate user action.

## Guardrails

- Propose, never auto-apply (AC-2 / AC-13). A run with no approval mutates nothing the user owns.
- Detect from files that EXIST; never assert a stack you didn't read a manifest for.
- Only `.pending-profile` removal + an explicitly-approved scaffold copy / gate edit are writes — and
  only after approval.

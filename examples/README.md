# Examples — project-specific gates (not mounted)

These are **documented examples, not mounted hooks**. They never run unless you copy one into your own `~/.claude/hooks/` and wire it in your `settings.json`. They show how to author a gate that encodes YOUR project's topology — the framework keeps these OUT of the mounted set because they hardcode a board format, a prod host, or a worktree layout that isn't generic.

Each example has its project-specific literals replaced with `<placeholder>` tokens and a header comment explaining how to adapt it.

## What's here

| Example | What it gates | Adapt by setting |
|---|---|---|
| `backlog-sop-validate.example.mjs` | Board-as-truth: validates that your `BACKLOG.md` cards follow the framework's card format (status whitelist + required fields). Read-only. | `AAL_BACKLOG` → your board path |
| `require-runbook-before-server-op.example.mjs` | Server-op gate: denies a prod operation unless the recent transcript shows you READ a runbook first (fail-closed). | the `PROD_OP` patterns → your host / deploy script / ingest CLI |
| `block-deploy-from-worktree.example.sh` | Prod-topology gate: allows production-mutating commands ONLY from the canonical checkout on clean `main`, never from a feature worktree. (A narrow variant — deny the `ssh user@host` form to force a host-alias instead — is a one-line tweak to the `IS_SSH_HOST` match in this same example.) | `<your-canonical-checkout>` / `<your-host>` / `<your-repo>` |
| `roster-board-aware.example.sh` | Board-as-truth roster tripwire: warns when the live team exceeds the cap AND cross-references each member's wave-slug against your active board(s) to flag the exact STALE agents to shut down. Read-only (besides the >2-day dead-team prune). | `AAL_BOARDS` → your board path(s), `;`-separated |
| `kotlin-lint.example.sh` | Kotlin/Compose stack lint: enforces naming, structured logging, file-size, and reliability invariants on a changed `.kt` file, with agent-readable fix instructions. | `<PROJECT_DIR>` / `<your/source/root>`; adapt the rules to your conventions |
| `arch-layer-lint.example.sh` | Kotlin/Compose stack lint: forward-only layer dependencies (entity → dao → repository → worker → viewmodel → ui); flags a lower layer importing a higher one. | `<PROJECT_DIR>` / `<your/source/root>` / `<your.app.package>` / `<your-data-service-dirs>` |
| `enforce-layer-deps.example.sh` | Kotlin/Compose stack lint: PostToolUse trigger that runs `arch-layer-lint` on a just-edited `.kt` file and warns on a layer violation. | `<PROJECT_DIR>` / `<your-project-marker>`; the path to your copy of `arch-layer-lint` |
| `golden-gc-scan.example.sh` | Kotlin/Compose stack scan (report, not a gate): scattered helpers, unsafe casts, multi-class files, star imports, oversized files, missing CancellationException rethrows, hardcoded UI strings, LiveData usage. | `<PROJECT_DIR>` / `<your/source/root>` / `<your-helper-patterns>` |
| `kt-compile-check.example.sh` | Kotlin/Compose stack reminder: non-blocking PostToolUse nudge to verify the build after a `.kt` edit. | the source extension + the build command in the reminder text |
| `block-stale-worktree-pytest.example.sh` | Python stale-worktree test gate: denies a worktree `pytest` lacking `PYTHONPATH=src` when the venv editable-install points at the main checkout (so the worktree run doesn't silently test main). | `<your-worktree-marker>` / `<your-test-root>` / `<your.module.path>` |

## Stack examples (adapt the pattern)

These two are NOT gates — they are **stack-specific skill patterns** (Android/Gradle) from the
source framework, kept as `.md` documentation. They are NOT under `skills/`, so they are never
auto-discovered or mounted. Copy one into your own `skills/<name>/SKILL.md` with generic
frontmatter to make it a real skill, after adapting it to your stack.

| Example | What it shows | Adapt by replacing |
|---|---|---|
| `build-apk.md` | Build the app artifact | the build command + the OOM handling + the artifact path |
| `test-runner.md` | Run + parse the unit test suite | the test command + the JDK/toolchain pin + the output-parsing step |

## The broader excluded family

The source framework also carries project-specific gates for partial-publish blocking, spec-branch-push blocking, and stale-base merge blocking. They aren't shipped here (sanitization surface + bloat) — the examples above are representative. (Several gates the source framework once carried only as examples — op-log/board reconciliation, multi-worktree-per-wave blocking, render-finding Playwright guards, and walk-before-next-merge reminders — are now genericized and MOUNTED in this plugin; see the gate-group tables in the [root README](../README.md).) If you want the full cookbook, read this repo's git history for the original bodies and adapt them to your project.

## How to use one

1. Copy the file into your `~/.claude/hooks/` (drop the `.example` from the name).
2. Replace every `<placeholder>` with your project's actual values.
3. If it's a `.mjs`/`.sh` that sources `lib/parse-json.sh`, make sure your hooks dir has that lib (it ships with this plugin at `hooks/lib/`).
4. Wire it in your `settings.json` `hooks` block on the appropriate event/matcher.
5. Test it against a known trigger before trusting it (a gate that fails open is decorative).

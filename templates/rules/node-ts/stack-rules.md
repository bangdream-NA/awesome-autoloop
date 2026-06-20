# Stack rules — Node + TypeScript (pnpm)

> Generic scaffold. Replace every `<placeholder>` with your project's real value, delete the rules
> that don't apply, and add your own. These are conventions a capable model won't infer from the
> code alone — keep the list short and specific to THIS stack.

## Test & build

- **Test:** run the package's own runner, scoped to the workspace you touched — e.g.
  `pnpm -F <pkg> test` (or `<your-test-cmd>`). A green run of the WHOLE suite, not just the file you
  edited, is the bar before you report done.
- **Build:** `pnpm build` (or `<your-build-cmd>`). If the wave touches the build pipeline, run the
  build, not just typecheck.
- **Typecheck + lint** are separate gates from test — run all three; a green test with a type error
  still fails CI.

## ESM & imports

- ESM-only project: use an explicit `.js` import suffix where Node's ESM resolver needs it (importing
  a sibling `.ts` resolves to `.js` at runtime). A missing suffix passes the type-checker but fails at
  runtime.
- No orphan compiled `.js` next to a `.ts` in `src/` — a stale emit shadows the source. Delete any
  `<pkg>/src/**/*.js` that isn't intentionally hand-authored.

## Worktree-local installs

- Dependency installs are worktree-LOCAL. Run `pnpm install` ONLY in your own worktree, never in the
  shared main checkout — a local env quirk is CI-authoritative, don't "fix" it by reinstalling main.
- The lockfile is the source of truth; commit it when you add a dependency.

## Live-verify (definition of done)

- **Web app:** a real-browser walk of the live page — not curl, not "the code looks right". Read a
  screenshot of the rendered surface; for any data-driven view, cross-check the rendered records
  against the published data (count + placement + de-dup), not just "no console errors".
- **CLI / library:** run the built binary / exercise the public API against a real input and observe
  the output — a passing unit test is necessary, not sufficient.

## Edge tests (mandatory)

- Boundary: null, empty, zero, negative, off-by-one, max.
- Network/boundary inputs (env, DB rows, API responses): accept null / unknown shape / parse failure
  explicitly. Never `JSON.parse` a value that may already be parsed — typeof-check first.
- Final-state assertions must be data-shape independent.

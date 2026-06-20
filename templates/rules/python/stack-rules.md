# Stack rules — Python

> Generic scaffold. Replace every `<placeholder>` with your project's real value, delete the rules
> that don't apply, and add your own. These are conventions a capable model won't infer from the
> code alone — keep the list short and specific to THIS stack.

## Test & lint

- **Test:** `pytest` (or `<your-test-cmd>`). Run the whole suite, not just the file you edited,
  before reporting done.
- **Lint / type:** run your linter + type-checker (e.g. `ruff` / `mypy`, or `<your-lint-cmd>`) as
  separate gates from test — a green test with a type error still fails CI.

## Worktree-local environment

- The virtualenv is worktree-LOCAL: create/activate the `.venv` inside YOUR worktree, never reuse the
  main checkout's. A local env quirk is CI-authoritative — don't "fix" it by touching main's env.
- **`PYTHONPATH=src` (editable-install gotcha):** if the project uses a `src/` layout with an editable
  install, an editable `.venv` may point at the MAIN src — running `pytest` in a worktree without
  `PYTHONPATH=src` (or a fresh `pip install -e .`) silently tests STALE main code. A RED that isn't
  the bug and a green that isn't the fix both come from this. Clear `__pycache__` and assert
  `module.__file__` resolves to YOUR worktree before trusting a result.

## Migrations

- A `schema.sql` change does NOT migrate an existing DB. Write the `ALTER` migration alongside the
  schema change in the same PR, and verify it replays on a POPULATED DB, not just a fresh one.

## Live-verify (definition of done)

- Data pipeline / service: do a post-deploy real run against the live service (CI can't exercise live
  creds/services) and verify the downstream artifact actually changed — a green CI run is necessary,
  not sufficient.

## Edge tests (mandatory)

- Boundary: null, empty, zero, negative, off-by-one, max.
- Boundary inputs (env, DB rows, network responses): accept None / unknown shape / parse failure
  explicitly. No silent catch-and-swallow — log + surface or re-raise.

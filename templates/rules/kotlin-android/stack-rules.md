# Stack rules — Kotlin / Compose / Android

> Generic scaffold. Replace every `<placeholder>` with your project's real value, delete the rules
> that don't apply, and add your own. These are conventions a capable model won't infer from the
> code alone — keep the list short and specific to THIS stack.

## Build & test

- **Build:** `./gradlew assembleDebug` (set `JAVA_HOME` to your SDK's JDK if there's no global one).
- **Test:** `./gradlew testDebugUnitTest` (or `<your-test-cmd>`). Run the suite, not just the file you
  edited.
- **Lint:** run your Kotlin linter (e.g. ktlint / detekt, or `<your-lint-cmd>`) as a separate gate.

## Architecture

- **MVVM + Clean layers:** keep `ui` / `domain` / `data` separated; UI depends on domain, domain
  depends on nothing app-specific. Don't let a Composable reach into the data layer directly.
- **Hilt scopes:** scope dependencies correctly (`@Singleton` / `@ViewModelScoped` / `@ActivityScoped`)
  — a mis-scoped binding is a leak or a crash, not a style nit.
- **State:** prefer `StateFlow` over `LiveData` for new state; hoist state to the ViewModel and keep
  Composables stateless. No `!!` force-unwraps — use null safety; coroutines for async.

## Migrations

- A Room entity / `schema.sql` change does NOT migrate an installed DB. Write the Room `Migration`
  alongside the schema change in the same PR and verify it replays on a POPULATED DB.

## Live-verify (definition of done)

- Install + launch the build on a device or emulator, drive the changed screen, and read a screenshot
  of the rendered surface — a green unit test is necessary, not sufficient. Verify configuration
  changes (rotation, theme) don't drop state.

## Edge tests (mandatory)

- Boundary: null, empty, zero, negative, off-by-one, max.
- UI: empty state, very long strings, rapid input, configuration changes.
- Concurrency: parallel coroutines, race conditions on shared state.
- Boundary inputs (network responses, DB rows): accept null / unknown shape / parse failure
  explicitly. No silent catch-and-swallow.

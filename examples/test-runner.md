# Example (NOT installed): test-runner — Android/Gradle stack

> A stack-specific skill from the source framework, kept here as a PATTERN, not a mounted skill.
> To adapt to YOUR stack, replace: the test command, the JDK/toolchain pin, and the output-parsing
> step. Copy into your own `skills/<name>/SKILL.md` with generic frontmatter, then it auto-discovers.
> (Left under `examples/` it is just documentation — it is NOT auto-discovered or mounted, so it
> never runs as-is.)

## The pattern (Android/Gradle)

Run the unit test suite and report results.

1. Run the tests:
   ```bash
   cd <project-root> && JAVA_HOME=<jdk> ./gradlew testDebugUnitTest 2>&1
   ```

2. Parse the output:
   - Count total tests, passed, failed, skipped.
   - If any tests failed, show the failing `test class:method` and the assertion error.
   - Distinguish a build failure from a test failure (different error patterns).

3. Report the summary:
   - `Total: X passed, Y failed, Z skipped`.
   - If all passed: confirm a clean run.
   - If failures: list each failing test with its error message.
   - If the build failed: show the compilation error.

4. If asked to fix failures, investigate the failing tests and fix the implementation — not the
   tests, unless the tests themselves are wrong.

## Adapt to your stack

- **Test command** — swap `./gradlew testDebugUnitTest` for your runner (`npm test`,
  `pytest -q`, `cargo test`, `go test ./...`).
- **JDK / toolchain pin** — `JAVA_HOME=<jdk>` is JVM-specific; replace with your toolchain's
  selector or drop it if the default works.
- **Output parsing** — every runner reports pass/fail/skip differently; adapt step 2 to your
  runner's summary format so the report in step 3 is accurate.

# Example (NOT installed): build-apk — Android/Gradle stack

> A stack-specific skill from the source framework, kept here as a PATTERN, not a mounted skill.
> To adapt to YOUR stack, replace: the build command, the OOM handling, the artifact path, and the
> output-parsing step. Copy into your own `skills/<name>/SKILL.md` with generic frontmatter, then it
> auto-discovers. (Left under `examples/` it is just documentation — it is NOT auto-discovered or
> mounted, so it never runs as-is.)

## The pattern (Android/Gradle)

1. Ensure the working directory is the root project (not a nested `android/android/`).
2. Build the debug artifact:
   ```bash
   cd <project-root>/android && ./gradlew assembleDebug 2>&1
   ```
3. If the build OOMs, raise the Gradle JVM heap — add `org.gradle.jvmargs=-Xmx4g` to
   `gradle.properties`.
4. If files are missing, check `git status` and restore from git history.
5. Artifact location: `<project-root>/android/app/build/outputs/apk/debug/app-debug.apk`.

## Adapt to your stack

- **Build command** — swap `./gradlew assembleDebug` for your artifact build (`npm run build`,
  `cargo build --release`, `go build`, `make`).
- **OOM handling** — the `-Xmx4g` bump is JVM-specific; your stack has its own resource knob (or
  none).
- **Artifact path** — point step 5 at wherever your build emits its binary/bundle.
- **JDK / toolchain** — if your build needs a specific JDK, set it explicitly
  (`JAVA_HOME=<jdk>`), the same way the `test-runner` example does.

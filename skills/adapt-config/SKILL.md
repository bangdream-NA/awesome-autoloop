---
name: adapt-config
description: Adapt agents/skills/hooks/settings to a SPECIFIC project (different from where they were originally authored). Read the project's conventions FIRST, then match commands/regexes/permissions to its actual stack — don't bring in another project's patterns.
---

# Adapt Config to Project

Use this skill when adapting agents/skills/hooks/settings to a SPECIFIC project (different from where they were originally authored).

Trigger phrases: "adapt the hooks to this project", "make the agents support X", "project-level .claude config", "rewrite the configs for this repo".

## Mandatory pre-work — read the project FIRST

Before editing any agent/skill/hook/settings:

1. **Read project conventions**
   - `README.md` (+ localized READMEs) — what this project IS
   - `CLAUDE.md` — project-level rules (if it exists)
   - `package.json` / `pnpm-workspace.yaml` / `Cargo.toml` / `build.gradle` / etc. — the runtime stack
   - `.github/workflows/*` — the CI surface, what gates exist
   - top-level `docs/` — documentation conventions
   - `scripts/` — deploy/maintenance entry points

2. **Classify the project runtime**
   - Web monorepo (Next/Hono/ORM, pnpm)?
   - Android/Kotlin (Gradle)?
   - Python/Node/Go/Rust/etc.?
   - This determines which hooks/skills make sense.

3. **List existing conventions**
   - Test framework (vitest/jest/junit/pytest/etc.)
   - Lint setup (eslint, ktlint, shellcheck, ruff)
   - Commit format (conventional? freeform?)
   - Deploy channels (CF/Vercel/VPS/etc.)
   - Branch protection / PR template

4. **Only THEN patch agents/settings/hooks**
   - Match the agents' commands to the project's actual scripts
   - Make hook regexes match the project's actual paths
   - Permissions allow the project's actual deploy/build commands
   - Don't bring in patterns from a different project's needs

## Anti-pattern

Writing agent definitions that reference one project's source paths (e.g. an Android app's package dirs) inside a different project's session — or extending a global hook with a regex that only matches one project when the user has several. **Read THIS project's actual files first.**

## Output structure

When done adapting:
1. List exactly what was changed and where (file:line)
2. List which project conventions you read and applied
3. Flag anything where you guessed because the convention wasn't clear — surface for a user lock

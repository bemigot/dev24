# scripts/

Developer tooling scripts for the p24core project.

## docker-setup.ps1

Container runtime check and setup (Docker or Podman). Dot-sourced by
`check-prerequisites.ps1` — shares its `$errors`, `$warnings`, `$missing`,
and `$warningMessages` variables.

## verify.sh / verify.ps1 (planned)

A single "is this change safe to merge?" entrypoint — runs install, lint,
typecheck, tests, and build. CI would run the same script so local and CI
failures are identical.

See the [JetBrains Agentization Cookbook](https://www.jetbrains.com/help/air/agentization-cookbook.html)
for the recipe and rationale.

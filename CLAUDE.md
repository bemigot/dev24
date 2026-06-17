# dev24 — Agent Instructions

## What this repo is

`dev24` is a developer environment toolkit. Its primary artifact is `check-req.py`,
a report-only prerequisite checker that inspects a machine and recommends fixes.
It currently supports macOS and Linux. Windows support is the active work item.

A legacy `check-prerequisites.ps1` (and the `scripts.tmp/` PowerShell set) also lives
in the repo. Unlike the checker, it both **checks and installs** — it predates the
report-only design and is transitional work to be refactored away and folded into
`check-req.py`, not a pattern to extend.

The `VM/` directory contains a KVM/libvirt harness (Python + virsh) used by the
maintainer to test `check-req.py` against ephemeral Windows VMs on pug.lan.

## Design principles

- **Report-only checker.** `check-req.py` never installs or mutates anything — it
  prints recommended shell commands and the developer runs them. (The legacy
  `check-prerequisites.ps1` predates this rule and does install; it is transitional,
  not a model to extend.)
- **No dependencies beyond stdlib.** `check-req.py` and `lib/dev/` must run on a
  fresh machine with only Python 3.8+ available.
- **Fix text is OS-tailored.** `IS_MAC`, `IS_WIN`, `IS_LINUX` in `lib/dev/core.py`
  gate which package-manager commands appear in fix strings, not which checks run.
- **One target project's toolchain.** `check-req.py` checks for the specific
  toolchain a single project needs (JDK 21, Node 20, Docker, Postgres, pixi, …).
  That project's repo layout is currently hardcoded — see the layout constants
  (`SPA_DIR`, `ENV_FILE` in `project.py`; `BFF_DIR` in `toolchain.py`), flagged for
  revision. Don't broaden scope to unrelated tools without explicit instruction.

## Module map

```
check-req.py          # entry point; takes <repo_root>; orchestrates modules; prints results
lib/dev/
  core.py             # Context, Result, Status, IS_MAC/WIN/LINUX, shell helpers
  preflight.py        # macOS-only: Homebrew + Python bootstrap gate
  toolchain.py        # mise, JDK, Node, npm, pixi, Python
  containers.py       # Docker daemon, Postgres reachability
  project.py          # repo-local checks (env.sh, validator deps, …)
sample-project/       # self-contained fixture for repo_root (./check-req.py sample-project)
VM/
  harness.py          # KVM/libvirt spin-up / teardown (maintainer only)
  win-vm.xml          # libvirt domain template
  README.md           # how to build/use the golden image

# transitional / maintainer-only (not the report-only end state):
check-prerequisites.ps1 # legacy Windows check+install; to be dissolved into check-req.py
scripts.tmp/          # legacy PowerShell setup scripts + helpers
links/                # maintainer symlinks into the local target-project checkout
```

## Adding a check

1. Decide which module it belongs to (`toolchain`, `containers`, `project`).
2. Add a function returning `Result.ok/warn/fail(...)` with fix strings tailored
   to the OS using `IS_MAC` / `IS_WIN` / `IS_LINUX`.
3. Register it in the module's `checks(ctx) -> list[Result]` function.
4. No new dependencies — stdlib only.

## Windows port (active work)

Goal: `check-req.py` runs on Windows (PowerShell / cmd / Git Bash) and produces
the same structured output with Windows-appropriate fix commands.

Key gaps to address:
- **Python bootstrap.** `check-req.py` is a Python program, but Windows ships no
  Python — so it can't run until Python is installed (`winget install Python` or
  similar). That step has to happen before the checker; today it lives only in the
  legacy `check-prerequisites.ps1` / `scripts.tmp/python-setup.ps1`.
- `which()` → `shutil.which()` already works on Windows; verify it
- Fix strings in `toolchain.py` / `containers.py` / `project.py` need Windows
  equivalents (winget, choco, or manual download links)
- `containers.py`: Docker Desktop on Windows exposes the same socket; check
  `//./pipe/docker_engine` or fall back to TCP
- `project.py`: path separators, `env.sh` vs `env.bat` equivalence
- Color/ANSI: Windows Terminal supports it; cmd.exe may not — gate on
  `os.get_terminal_size()` or `colorama` (but colorama is a dependency; prefer
  a `--no-color` default on Windows unless WT is detected)

## VM harness (VM/)

The harness creates disposable Windows VMs using qcow2 overlay images:

```
golden-win.qcow2   ← never modified; JDK/Node/Git pre-installed, repo cloned
run-overlay.qcow2  ← created fresh per run, discarded after
```

Workflow: create overlay → boot VM → SSH in → run `check-req.py` → observe →
destroy overlay. `harness.py` drives this via `libvirt` Python bindings.

## What NOT to do

- Don't add installer logic — this tool recommends, never acts.
- Don't broaden scope beyond the target project's toolchain.
- Don't add pip dependencies to the checker itself.
- Don't commit VM images or credentials.

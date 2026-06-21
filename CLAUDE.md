# dev24 — Agent Instructions

## What this repo is

`dev24` is a developer environment toolkit. Its primary artifact is `check-req.py`,
a prerequisite checker that inspects a machine, reports readiness, and can apply
fixes interactively. It currently supports macOS and Linux. Windows support is the
active work item.

A legacy `check-prerequisites.ps1` (and the `scripts.tmp/` PowerShell set) also lives
in the repo. It both **checks and installs**, with interactive y/N prompts — the
model `check-req.py` now adopts, with the legacy scripts being folded into it. The
**one permanent exception** is the pre-checker Python bootstrap on Windows: a Python
program can't install the Python that runs it, so that step stays in PowerShell by
necessity (`VM/cd/ubootstrap.ps1`; see Windows port).

dev24 itself ships **no `pixi.toml`** — pixi is the *target project's* tooling-Python
provider, which the checker only observes. The VM harness uses system `python3` +
the `python3-libvirt` package; the Windows Python bootstrap is PowerShell's job.
Neither needs pixi.

The `VM/` directory contains a KVM/libvirt harness (Python + virsh) used by the
maintainer to test `check-req.py` against ephemeral Windows VMs on pug.lan.

## Design principles

- **Check-and-fix checker.** `check-req.py` reports what's wrong and can apply the
  fix, offered interactively per finding (`apply? [y/N]`; `--yes` applies all,
  `--report-only` is the historical recommend-only behavior). A check makes itself
  self-healing by attaching a `Result.fix` action; checks without one stay
  report-only, and a non-TTY run never mutates unless `--yes`.
- **No dependencies beyond stdlib.** `check-req.py` and `lib/dev/` must run on a
  fresh machine with only Python 3.8+ available.
- **Fixes are OS-tailored.** `IS_MAC`, `IS_WIN`, `IS_LINUX` in `lib/dev/core.py`
  gate which package-manager commands appear in fix text (and which fix actions
  run), not which checks run.
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
  SPEC.md             # design of the Windows VM harness (read this first)
  harness.py          # KVM/libvirt bring-up / teardown (maintainer only)
  win-vm.xml          # libvirt VM definition
  README.md           # host setup + how to mint the golden image
  cd/                 # control-CD scripts (ubootstrap.ps1, cboot1.ps1)

# legacy / maintainer-only:
check-prerequisites.ps1 # legacy Windows check+install; being dissolved into check-req.py
scripts.tmp/          # legacy PowerShell setup scripts + helpers
links/                # maintainer symlinks into the local target-project checkout
```

## Adding a check

1. Decide which module it belongs to (`toolchain`, `containers`, `project`).
2. Add a function returning `Result.ok/warn/fail(...)` with fix strings tailored
   to the OS using `IS_MAC` / `IS_WIN` / `IS_LINUX`; optionally pass a `fix=`
   callable to make it self-healing (the runner offers it as `apply? [y/N]`).
3. Register it in the module's `checks(ctx) -> list[Result]` function.
4. No new dependencies — stdlib only.

## Windows port (active work)

Goal: `check-req.py` runs on Windows (PowerShell / cmd / Git Bash) and produces
the same structured output with Windows-appropriate fix commands.

Key gaps to address:
- **Python bootstrap.** `check-req.py` is a Python program, but Windows ships no
  Python — so it can't run until Python is installed (`winget install Python` or
  similar). That step has to happen before the checker; today it lives only in the
  legacy `check-prerequisites.ps1` / `scripts.tmp/python-setup.ps1`. This is a
  **permanent split-out, not transitional** — it can't fold into `check-req.py`
  (the program can't install its own interpreter). Keep it a thin
  report-then-bootstrap PowerShell step; pixi is *not* used for it.
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

Maintainer-only KVM/libvirt harness for testing `check-req.py` on a bare Windows
VM. **`VM/SPEC.md` is the design** — golden image, persistent `go1` overlay,
the per-run control CD, the `ubootstrap.ps1` / `cboot1.ps1` scripts, and the
`harness.py` verbs. See `VM/README.md` for host setup and minting the image.

The golden image is a plain Windows 11 install with nothing baked on top; the
control CD and the scripts under test provision everything at run time.

Note: the committed `harness.py` still encodes the older provisioned-image model
(SSH in, `git pull`, `python3 check-req.py`); rewriting it to SPEC is the active
work item.

## What NOT to do

- Fixers must be gated through `confirm()` — never mutate on a non-TTY unless
  `--yes`; and keep the fix OS-tailored.
- Don't broaden scope beyond the target project's toolchain.
- Don't add pip dependencies to the checker itself.
- Don't commit VM images or credentials.

# dev24

Developer environment toolkit for polyglot multiplatform projects.

## Quick start (macOS / Linux)

```bash
cd ~ && git clone https://github.com/bemigot/dev24.git && cd dev24
./check-req.py /path/to/your/repo
```

To try it with no target repo of your own, run it against the bundled fixture —
the repo-local checks resolve against it, the rest reflect your machine:

```bash
./check-req.py sample-project
```

`check-req.py` inspects your machine and reports what's missing. For most findings it
can apply the fix for you, offered one at a time (`apply? [y/N]`); pass `--yes` to
apply all, or `--report-only` to just print the steps and apply them yourself.

Once it reports **READY**, your environment is set up and you can start developing.
Come back here only to troubleshoot your setup.

## What's in this repo

| Path | Purpose |
|------|---------|
| `check-req.py` | Prerequisite checker — reports, and applies fixes interactively (macOS/Linux; Windows in progress) |
| `lib/dev/` | Checker modules: `toolchain`, `containers`, `project`, `preflight`, `core` |
| `sample-project/` | Self-contained fixture to run the checker against (`./check-req.py sample-project`) |
| `VM/` | KVM/libvirt harness for ephemeral Windows VMs (maintainer use) |
| `doc/` | Setup troubleshooting notes (placeholder) |
| `check-prerequisites.ps1`, `scripts.tmp/` | Legacy Windows check-and-install scripts — being folded into `check-req.py` |

## Windows

Windows support for `check-req.py` is under active development. Unlike macOS/Linux,
Windows ships no Python, so it must be installed *before* the checker can run at all.

The minimal bootstrap is `VM/cd/ubootstrap.ps1` — a self-contained script that
installs Python (and only Python) via winget. On a bare box:

```powershell
powershell -ExecutionPolicy Bypass -File .\ubootstrap.ps1
```

If you downloaded it through a browser, Windows tags it with the Mark-of-the-Web,
so clear that first — `Unblock-File .\ubootstrap.ps1` — or just use the
`-ExecutionPolicy Bypass -File` form above, which runs it regardless. (The fuller
legacy install path still lives in `check-prerequisites.ps1` /
`scripts.tmp/python-setup.ps1`, pending a proper Windows entry point.)

The `VM/` directory contains a KVM harness used to test the checker against a clean
Windows VM.

## Usage

```
./check-req.py <repo_root> [--database <name>] [--no-color]
```

- `repo_root` — path to the project checkout to inspect (required)
- `--database` — expected DB name in `env.sh` (default: `hello`)
- `--no-color` — plain text output (useful in CI or terminals without ANSI)

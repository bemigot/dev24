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

`check-req.py` inspects your machine and prints corrective steps for anything missing.
It only reports — it never installs or changes anything; you review and apply the
fixes, then re-run. (The legacy `check-prerequisites.ps1` is the exception — it both
checks and installs; see [Windows](#windows).)

Once it reports **READY**, your environment is set up and you can start developing.
Come back here only to troubleshoot your setup.

## What's in this repo

| Path | Purpose |
|------|---------|
| `check-req.py` | Report-only prerequisite checker (macOS/Linux; Windows in progress) |
| `lib/dev/` | Checker modules: `toolchain`, `containers`, `project`, `preflight`, `core` |
| `sample-project/` | Self-contained fixture to run the checker against (`./check-req.py sample-project`) |
| `VM/` | KVM/libvirt harness for ephemeral Windows VMs (maintainer use) |
| `doc/` | Setup troubleshooting notes (placeholder) |
| `check-prerequisites.ps1`, `scripts.tmp/` | Legacy Windows check-and-install scripts — transitional, to be folded into the report-only checker |

## Windows

Windows support for `check-req.py` is under active development. Unlike macOS/Linux,
Windows ships no Python, so it must be installed *before* the checker can run at all —
that bootstrap currently lives only in the legacy `check-prerequisites.ps1` /
`scripts.tmp/python-setup.ps1`, pending a proper Windows entry point.

The `VM/` directory contains a KVM harness used to test the checker against a clean
Windows VM.

## Usage

```
./check-req.py <repo_root> [--database <name>] [--no-color]
```

- `repo_root` — path to the project checkout to inspect (required)
- `--database` — expected DB name in `env.sh` (default: `hello`)
- `--no-color` — plain text output (useful in CI or terminals without ANSI)

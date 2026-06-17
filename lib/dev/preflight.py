"""macOS preflight gates — hard preconditions checked before everything else.

Two things make the rest of the report meaningless on a fresh Mac:

  * No Homebrew. Nearly every macOS fix below installs via `brew` (colima, the
    docker CLI, JDKs, pixi…); without it the recommendations are dead ends.
  * A stale system Python. macOS ships /usr/bin/python3 at 3.9, but the e2e
    tooling (this checker, scripts/pixi.toml, the F4 validators) targets 3.12+.

When either gate fails we stop the run immediately (see check-req.py) rather than
emit a wall of downstream failures, and point at one bootstrap recipe: Homebrew →
pixi → a modern Python (3.14) from `pixi install`. No-op on Linux/Windows — this
module is only invoked when core.IS_MAC is true.
"""
from __future__ import annotations

from .core import Context, Result, pixi_env_python, python_version, run, which

GROUP = "Preflight (macOS)"

PY_MIN = (3, 12)

# The one true bootstrap path on macOS, newest-best first. pixi install reads
# scripts/pixi.toml (python = ">=3.12", resolves 3.14+) and also pulls the
# validator deps, so it doubles as the Python-3.14 install.
BOOTSTRAP = [
    'install Homebrew: /bin/bash -c "$(curl -fsSL '
    'https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"',
    "then: brew install pixi",
    "then, in the repo: cd scripts && pixi install   # provides Python 3.14 for the e2e tooling",
]


def _homebrew() -> Result:
    if not which("brew"):
        return Result.fail(
            "Homebrew",
            "not found — required to install colima, the docker CLI, JDKs, pixi…",
            fixes=BOOTSTRAP,
        )
    _, out = run(["brew", "--version"])
    return Result.ok("Homebrew", out.splitlines()[0].strip() if out else "present")


def _python(ctx: Context) -> Result:
    # Gate the interpreter the e2e tooling will actually use: the scripts/ pixi env
    # once `pixi install` has created it, else the system python3 (macOS ships 3.9,
    # too old). Mirrors project._e2e_python so the gate matches the real target.
    py = pixi_env_python(ctx.repo_root) or "python3"
    where = "pixi env" if py != "python3" else "system"
    ver = python_version(py)
    if ver is None:
        return Result.fail("Python 3", f"{where} python not runnable ({py})", fixes=BOOTSTRAP)
    label = f"Python {ver[0]}.{ver[1]} ({where})"
    if ver >= PY_MIN:
        return Result.ok("Python 3", label)
    # A too-old interpreter lands here — the macOS system 3.9 being the usual case.
    return Result.fail(
        "Python 3",
        f"{label} — need 3.12+ (too old for the e2e tooling)",
        fixes=BOOTSTRAP,
    )


def checks(ctx: Context) -> list[Result]:
    return [_homebrew(), _python(ctx)]

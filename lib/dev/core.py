"""Shared primitives for the readiness checker (check-req.py).

Checks describe what's wrong, recommend corrective steps, and may attach a fix
action the runner applies interactively (prompted per fix; see Result.fix,
set_fix_mode, and confirm). A check with no fix action stays report-only.
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from enum import Enum
from typing import Callable

# Host OS - checks tailor their *fix* text to the platform's package manager and
# service model (brew + colima on macOS, apt + systemd on Linux). Detection only;
# nothing here behaves differently beyond which recommendation string is printed.
IS_MAC = sys.platform == "darwin"
IS_WIN = sys.platform.startswith("win")
IS_LINUX = sys.platform.startswith("linux")


# Severity ladder - decided by one question: does it block an e2e run?
#
#   +---------+---------------------------------+-----------------------------+
#   | Status  | Meaning                         | Effect                      |
#   +---------+---------------------------------+-----------------------------+
#   | OK      | fine (or no line when silent)   | -                           |
#   | WARN    | runnable, but off-spec or a     | advisory; does NOT block    |
#   |         | secondary/fallback is missing   | READY; exit code stays 0    |
#   | FAIL    | blocks the e2e run              | no READY; exit code 1       |
#   +---------+---------------------------------+-----------------------------+
#
# Current WARN producers (present-but-wrong-version, or a fallback is missing
# while a working path still exists -- none stop run-f4.sh from completing):
#
#   javac          version not 21/25/26 (present and usable, just untested)
#   Node.js        < v22                (present, likely still builds)
#   npm            < v10                (present, likely still works)
#   Docker engine  server < 20          (reachable, probably fine)
#   Python 3       < 3.10 (off the pixi path only; may still run validators)
#   pixi           not found            (pip3 fallback exists)
#   pip3           absent/unrunnable    (only when pixi is unusable; it is the
#                                         fallback installer)
#
# FAIL examples: required tool missing, no Postgres on :5432, no env.sh,
# missing Python validator deps, pixi on PATH but not runnable.
class Status(Enum):
    OK = "OK"
    WARN = "WARN"
    FAIL = "FAIL"


@dataclass
class Context:
    """Everything a check needs to know about this checkout/run."""
    repo_root: str   # path to the project checkout being inspected (required CLI arg)
    database: str    # expected DB name in env.sh; used in fix text + the env.sh check


@dataclass
class Result:
    name: str
    status: Status
    detail: str = ""
    # Recommended corrective steps, newest-best first. Each entry is one option
    # ("do A" / "or do B"); the orchestrator prints them.
    fixes: list[str] = field(default_factory=list)
    # Optional self-heal: a zero-arg callable that APPLIES the fix and returns
    # True on success. The runner offers it interactively (apply? [y/N]) per the
    # fix mode; checks that leave it None stay report-only.
    fix: Callable[[], bool] | None = None

    @classmethod
    def ok(cls, name, detail=""):
        return cls(name, Status.OK, detail)

    @classmethod
    def warn(cls, name, detail="", fixes=None, fix=None):
        return cls(name, Status.WARN, detail, fixes or [], fix)

    @classmethod
    def fail(cls, name, detail="", fixes=None, fix=None):
        return cls(name, Status.FAIL, detail, fixes or [], fix)


# --- fix application --------------------------------------------------------
# check-req.py applies fixes, not just recommends them. Mode:
#   "ask"  - prompt 'apply? [y/N]' per fix (default; auto-skips on a non-TTY)
#   "auto" - apply every offered fix without prompting (--yes)
#   "off"  - never apply; recommend only, the historical report-only behavior
#            (--report-only)
_FIX_MODE = "ask"


def set_fix_mode(mode: str) -> None:
    global _FIX_MODE
    _FIX_MODE = mode


def confirm(prompt: str) -> bool:
    """Whether to apply a fix, honoring the fix mode; never blocks a non-TTY."""
    if _FIX_MODE == "off":
        return False
    if _FIX_MODE == "auto":
        return True
    if not sys.stdin.isatty():
        return False
    try:
        return input(f"{prompt} [y/N] ").strip().lower() in ("y", "yes")
    except EOFError:
        return False


# --- shell helpers ----------------------------------------------------------

def which(name: str) -> str | None:
    return shutil.which(name)


def run(cmd: list[str], timeout: int = 10) -> tuple[int, str]:
    """Run a command, return (returncode, combined stdout+stderr). Never raises."""
    try:
        p = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout
        )
        return p.returncode, (p.stdout + p.stderr).strip()
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError) as e:
        return 127, str(e)


def first_int(text: str) -> int | None:
    """First integer found in `text` (e.g. major version)."""
    m = re.search(r"\d+", text)
    return int(m.group()) if m else None


def python_version(py: str) -> tuple[int, int] | None:
    """(major, minor) reported by an interpreter, or None if it can't be run/parsed."""
    rc, out = run([py, "--version"])
    if rc != 0:
        return None
    m = re.search(r"(\d+)\.(\d+)", out)
    return (int(m.group(1)), int(m.group(2))) if m else None


def pixi_env_python(repo_root: str) -> str | None:
    """Interpreter inside the scripts/ pixi env, or None until `pixi install`
    creates it. Once present it's the env the e2e Python tooling targets
    (scripts/pixi.toml); pixi being on PATH does NOT imply the env exists.
    """
    py = os.path.join(repo_root, "scripts", ".pixi", "envs", "default", "bin", "python")
    return py if os.path.isfile(py) else None


# --- terminal rendering -----------------------------------------------------

_USE_COLOR = sys.stdout.isatty() and "NO_COLOR" not in os.environ
_C = {
    Status.OK: "\033[32m",    # green
    Status.WARN: "\033[33m",  # yellow
    Status.FAIL: "\033[31m",  # red
}
_RESET = "\033[0m"
_DIM = "\033[2m"


def set_color(enabled: bool) -> None:
    global _USE_COLOR
    _USE_COLOR = enabled


def paint(status: Status) -> str:
    label = f"{status.value:<4}"
    if not _USE_COLOR:
        return label
    return f"{_C[status]}{label}{_RESET}"


def dim(text: str) -> str:
    return f"{_DIM}{text}{_RESET}" if _USE_COLOR else text

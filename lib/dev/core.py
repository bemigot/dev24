"""Shared primitives for the Linux readiness checker (scripts/check-req.py).

Report-only by design: checks describe what's wrong and *recommend* corrective
steps as plain text. Nothing here mutates the machine or runs a fix.
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from enum import Enum

# Host OS — checks tailor their *fix* text to the platform's package manager and
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
    # ("do A" / "or do B"); the orchestrator prints them, it never runs them.
    fixes: list[str] = field(default_factory=list)

    @classmethod
    def ok(cls, name, detail=""):
        return cls(name, Status.OK, detail)

    @classmethod
    def warn(cls, name, detail="", fixes=None):
        return cls(name, Status.WARN, detail, fixes or [])

    @classmethod
    def fail(cls, name, detail="", fixes=None):
        return cls(name, Status.FAIL, detail, fixes or [])


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

"""Per-checkout project state: config and installed dependencies.

These are the bits the .bat checked (node_modules) plus the Linux e2e extras:
env.sh, the Playwright browser, and the Python packages the validators import.
"""
from __future__ import annotations

import glob
import json
import os
import sys

from .core import (
    IS_MAC, Context, Result, pixi_env_python, python_version, run, which,
)

GROUP = "Project state"

# --- hardcoded, project-specific repo layout ----------------------------------
# TODO(revise): these encode one project's directory layout under repo_root. They
# should become configurable (or discovered) rather than baked in, so the checker
# isn't tied to a single project's structure.
SPA_DIR = "platform24-spa"   # frontend dir holding node_modules + the Playwright browser
ENV_FILE = "env.sh"          # backend datasource config expected at repo_root

# Imported by the F4 validators (docs/onboarding.md §1 + ppc needs pyyaml).
# Keys are import names, values are the package names to install.
# TODO(revisit): this list is hand-maintained. It was compiled from the output of
# scripts.tmp/list-imports.py run against the validators; re-derive it (or wire that
# helper in) when their imports change, rather than editing this dict by hand.
PY_E2E_PKGS = {"requests": "requests", "jsonschema": "jsonschema", "yaml": "pyyaml"}

# sample.env.sh ships the backend datasource URLs pointing at a placeholder DB;
# both the JDBC and R2DBC vars (…DATASOURCES_DEFAULT_URL) end in /<db> and must be
# repointed at the expected DB or the backend connects to the wrong database.
_DB_VAR = "DATASOURCES_DEFAULT_URL"  # substring of both DATASOURCES_… and R2DBC_…
_SAMPLE_DB = "hello"                  # the placeholder sample.env.sh ships with


def _e2e_python(ctx: Context) -> str:
    """Interpreter the e2e deps should be importable from.

    Once `scripts/pixi.toml` is installed, that's the env we target; until then
    fall back to bare python3 (what run-f4.sh's PYTHON_BIN resolves to today).
    """
    return pixi_env_python(ctx.repo_root) or "python3"


def _e2e_dep_fixes(missing: list[str]) -> list[str]:
    """Corrective options: pixi if present, else pip3 --user.

    On Linux/macOS pip refuses to touch an externally-managed Python without
    --break-system-packages (PEP 668); on Windows that flag isn't needed.
    """
    pkgs = " ".join(missing)
    if which("pixi"):
        return ["cd scripts && pixi install   # installs these into the pixi env"]
    if which("pip3"):
        flag = "" if sys.platform.startswith("win") else " --break-system-packages"
        return [f"pip3 install --user {pkgs}{flag}"]
    return ["install pixi (https://pixi.sh), then: cd scripts && pixi install"]


def _datasource_dbs(env_sh: str) -> list[str]:
    """DB names from the *DATASOURCES_DEFAULT_URL lines (…://host:port/<db>[?…])."""
    dbs = []
    try:
        with open(env_sh, encoding="utf-8") as f:
            for line in f:
                s = line.strip()
                if s.startswith("#") or _DB_VAR not in s or "postgresql://" not in s:
                    continue
                db = s.rsplit("/", 1)[-1].split("?")[0].strip().strip("\"'")
                if db:
                    dbs.append(db)
    except OSError:
        pass
    return dbs


def _env_sh(ctx: Context) -> Result:
    env_sh = os.path.join(ctx.repo_root, ENV_FILE)
    if not os.path.isfile(env_sh):
        return Result.fail(
            "env.sh",
            "missing - backend starts with 'No URL specified'",
            fixes=[
                # One step: strip comments and rewrite the placeholder DB in the
                # same pass (only the *DATASOURCES_DEFAULT_URL lines carry it).
                f"grep -v '^#' sample.env.sh | sed 's/{_SAMPLE_DB}/{ctx.database}/' >> env.sh",
                f"or: cp sample.env.sh env.sh, then point both *{_DB_VAR} at "
                f"/{ctx.database} (sample DB is '/{_SAMPLE_DB}')",
            ],
        )
    # Present, but a copied-and-forgotten /hello (or any DB != the expected one) makes
    # the backend connect to the wrong database - don't let that pass as OK.
    mismatched = sorted({db for db in _datasource_dbs(env_sh) if db != ctx.database})
    if mismatched:
        outcome = Result.fail if _SAMPLE_DB in mismatched else Result.warn
        return outcome(
            "env.sh",
            f"*{_DB_VAR} → /{', /'.join(mismatched)} - expected /{ctx.database}",
            fixes=[f"set the DB name to /{ctx.database} in env.sh "
                   f"(both the jdbc + r2dbc *{_DB_VAR} lines)"],
        )
    return Result.ok("env.sh", f"present (DB /{ctx.database})")


def _node_modules(ctx: Context) -> Result | None:
    # npm writes .package-lock.json on a complete ci/install; its absence means
    # missing or partial deps. Report only on failure - no success line.
    nm = os.path.join(ctx.repo_root, SPA_DIR, "node_modules")
    if os.path.isfile(os.path.join(nm, ".package-lock.json")):
        return None
    detail = "missing" if not os.path.isdir(nm) else "incomplete (no .package-lock.json)"
    return Result.fail("node_modules", f"{SPA_DIR}/node_modules {detail}",
                       fixes=[f"npm --prefix {SPA_DIR} ci"])


def _required_chromium_revision(ctx: Context) -> str | None:
    """Chromium build revision the installed Playwright pins, per its own
    browsers.json (e.g. "1223" for @playwright/test 1.60.0). None if Playwright
    isn't installed yet - then the required revision is unknowable.
    """
    bj = os.path.join(ctx.repo_root, SPA_DIR, "node_modules",
                      "playwright-core", "browsers.json")
    try:
        with open(bj, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return None
    for b in data.get("browsers", []):
        if b.get("name") == "chromium" and b.get("revision") is not None:
            return str(b["revision"])
    return None


def _playwright(ctx: Context) -> Result:
    # Browsers install under a per-OS cache dir: ~/.cache/ms-playwright on Linux,
    # ~/Library/Caches/ms-playwright on macOS. PLAYWRIGHT_BROWSERS_PATH overrides.
    default_cache = "~/Library/Caches/ms-playwright" if IS_MAC else "~/.cache/ms-playwright"
    cache = os.path.expanduser(
        os.environ.get("PLAYWRIGHT_BROWSERS_PATH") or default_cache
    )
    install = f"npx --prefix {SPA_DIR} playwright install chromium"
    # `chromium-*` matches the browser dir (chromium-<rev>) but not the separate
    # chromium_headless_shell-<rev> dir (underscore prefix), so this lists builds.
    present = sorted(os.path.basename(p)
                     for p in glob.glob(os.path.join(cache, "chromium-*")))

    rev = _required_chromium_revision(ctx)
    if rev is None:
        # Playwright not installed yet (node_modules check FAILs separately); the
        # pinned revision is unknown, so fall back to a presence-only probe.
        if present:
            return Result.ok("Playwright chromium", f"installed ({', '.join(present)})")
        return Result.fail("Playwright chromium", "no chromium browser found for Playwright",
                           fixes=[install])

    if os.path.isdir(os.path.join(cache, f"chromium-{rev}")):
        return Result.ok("Playwright chromium", f"chromium-{rev} (matches pinned Playwright)")
    # A chromium exists but not the pinned revision → stale; the e2e run would
    # re-download or fail. Treat a missing-altogether the same: needs an install.
    detail = (f"have {', '.join(present)} but Playwright needs chromium-{rev}" if present
              else f"chromium-{rev} not installed (required by pinned Playwright)")
    return Result.fail("Playwright chromium", detail, fixes=[install])


def _py_packages(ctx: Context) -> Result:
    py = _e2e_python(ctx)
    # Surface which interpreter and version actually carry the deps - the pixi env
    # once created, else system python3 - so a stale/old e2e Python is visible here
    # (preflight only gates this on macOS; this line covers Linux too).
    ver = python_version(py)
    where = ("pixi env" if py != "python3" else "python3")
    where += f", Python {ver[0]}.{ver[1]}" if ver else ""
    probe = "import " + ", ".join(PY_E2E_PKGS)
    if run([py, "-c", probe])[0] == 0:
        return Result.ok("Python e2e deps", f"{', '.join(PY_E2E_PKGS.values())} ({where})")
    missing = [pkg for mod, pkg in PY_E2E_PKGS.items()
               if run([py, "-c", f"import {mod}"])[0] != 0]
    # Blocking: run-f4's validators (masha/ppc/isabella/bear) import these.
    return Result.fail(
        "Python e2e deps",
        f"missing from {where}: {', '.join(missing)}",
        fixes=_e2e_dep_fixes(missing),
    )


def checks(ctx: Context) -> list[Result]:
    # Python e2e deps first: the F4 validators (masha/ppc/isabella/bear) all import
    # them, so a missing one is the most fundamental blocker in this group.
    results = [_py_packages(ctx), _env_sh(ctx), _node_modules(ctx), _playwright(ctx)]
    return [r for r in results if r is not None]

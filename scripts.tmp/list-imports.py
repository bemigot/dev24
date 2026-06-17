#!/usr/bin/env python3
"""
Sweep project directories for Python files, extract their imports, probe
each top-level package for availability, and report a three-section summary:
  1. Python files found  (* = has missing imports, ! = unparseable)
  2. Resolved third-party imports  (package → files that use it)
  3. Missing packages              (package → files that need it)

Usage:
    python scripts/list-imports.py [root_dir]   # default: repo root
"""

import ast
import importlib.util
import os
import sys
from collections import defaultdict
from pathlib import Path

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

SKIP_DIRS = {
    ".git", ".gradle", ".idea", ".pixi", ".venv",
    "__pycache__", "build", "dist", "node_modules", "target", "venv",
}

# ---------------------------------------------------------------------------
# File discovery
# ---------------------------------------------------------------------------

def _python_shebang(path: Path) -> bool:
    try:
        with path.open("rb") as f:
            line = f.readline(200)
        return line.startswith(b"#!") and b"python" in line
    except OSError:
        return False


def find_python_files(root: Path):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
        for name in sorted(filenames):
            p = Path(dirpath) / name
            if p.suffix == ".py" or (not p.suffix and _python_shebang(p)):
                yield p

# ---------------------------------------------------------------------------
# Import extraction
# ---------------------------------------------------------------------------

def extract_imports(path: Path):
    """Return (frozenset of top-level package names, error_str | None)."""
    try:
        source = path.read_text(encoding="utf-8", errors="replace")
        tree = ast.parse(source, filename=str(path))
    except SyntaxError as exc:
        return frozenset(), f"SyntaxError: {exc}"
    except Exception as exc:
        return frozenset(), str(exc)

    pkgs = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                pkgs.add(alias.name.split(".")[0])
        elif isinstance(node, ast.ImportFrom):
            if node.level == 0 and node.module:       # skip relative imports
                pkgs.add(node.module.split(".")[0])
    return frozenset(pkgs), None

# ---------------------------------------------------------------------------
# Stdlib detection
# ---------------------------------------------------------------------------

_STDLIB: frozenset = getattr(sys, "stdlib_module_names", frozenset())

if not _STDLIB:
    import sysconfig as _sc
    _stdlib_root = _sc.get_paths()["stdlib"]

    def _is_stdlib(name: str) -> bool:
        if name in sys.builtin_module_names:
            return True
        try:
            spec = importlib.util.find_spec(name)
            return bool(spec and spec.origin and spec.origin.startswith(_stdlib_root))
        except Exception:
            return False
else:
    def _is_stdlib(name: str) -> bool:
        return name in _STDLIB

# ---------------------------------------------------------------------------
# Package resolution
# ---------------------------------------------------------------------------

def _resolve(name: str) -> bool:
    """True if the package can be found by the current interpreter."""
    try:
        return importlib.util.find_spec(name) is not None
    except Exception:
        return False

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 \
           else Path(__file__).resolve().parent.parent

    # ---- collect files and their third-party imports ----
    file_pkgs:  dict[Path, frozenset[str]] = {}   # path -> non-stdlib imports
    file_error: dict[Path, str]            = {}   # path -> parse error

    for pyfile in find_python_files(root):
        pkgs, err = extract_imports(pyfile)
        if err:
            file_error[pyfile] = err
        file_pkgs[pyfile] = frozenset(p for p in pkgs if not _is_stdlib(p))

    # ---- local module names (bare stems of Python files in the project) ----
    # Imports that match a project file are project-internal; exclude from
    # "missing" so they don't pollute the missing-packages list.
    local_names: set[str] = {f.stem for f in file_pkgs}

    # ---- probe each package once ----
    all_pkgs: set[str] = set()
    for pkgs in file_pkgs.values():
        all_pkgs.update(pkgs)

    resolved_pkg: set[str] = set()
    missing_pkg:  set[str] = set()
    for pkg in all_pkgs:
        if pkg in local_names:
            continue
        (resolved_pkg if _resolve(pkg) else missing_pkg).add(pkg)

    # ---- build inverse maps (package → files) ----
    resolved: dict[str, list[Path]] = defaultdict(list)
    missing:  dict[str, list[Path]] = defaultdict(list)

    for pyfile, pkgs in file_pkgs.items():
        for pkg in pkgs:
            if pkg in local_names:
                continue
            if pkg in resolved_pkg:
                resolved[pkg].append(pyfile)
            elif pkg in missing_pkg:
                missing[pkg].append(pyfile)

    broken_files = {f for files in missing.values() for f in files}
    unparseable  = set(file_error)

    # ---- helpers ----
    def rel(p: Path) -> str:
        try:
            return str(p.relative_to(root))
        except ValueError:
            return str(p)

    col = 26   # alignment column for package names

    # ---- output ----
    n_broken = len(broken_files - unparseable)
    n_unparse = len(unparseable)
    summary_parts = [f"{len(file_pkgs)} total"]
    if n_broken:
        summary_parts.append(f"{n_broken} with missing imports (*)")
    if n_unparse:
        summary_parts.append(f"{n_unparse} unparseable (!)")
    print(f"Python files ({', '.join(summary_parts)}):")
    for f in sorted(file_pkgs):
        if f in unparseable:
            print(f"  {rel(f)}  !  {file_error[f]}")
        elif f in broken_files:
            print(f"  {rel(f)}  *")
        else:
            print(f"  {rel(f)}")
    print()

    print(f"Resolved third-party imports ({len(resolved)}):")
    if resolved:
        for pkg in sorted(resolved):
            files_str = ", ".join(rel(f) for f in sorted(resolved[pkg]))
            print(f"  {pkg:<{col}}{files_str}")
    else:
        print("  (none)")
    print()

    print(f"Missing packages ({len(missing)}):")
    if missing:
        for pkg in sorted(missing):
            files_str = ", ".join(rel(f) for f in sorted(missing[pkg]))
            print(f"  {pkg:<{col}}{files_str}")
    else:
        print("  (none)")


if __name__ == "__main__":
    main()

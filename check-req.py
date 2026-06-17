#!/usr/bin/env python3
"""Developer environment readiness checker for a project's dev toolchain.

Report-only: inspects the machine and recommends corrective steps.
Never installs or changes anything.

Usage:
    ./check-req.py <repo_root> [--database hello] [--no-color]

Exit code: 0 if no failures (warnings allowed), 1 if any check FAILed.

Supported platforms: macOS, Linux. Windows support is in progress.
"""
from __future__ import annotations

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from lib.dev import containers, preflight, project, toolchain  # noqa: E402
from lib.dev.core import IS_MAC, Context, Status, dim, paint, set_color  # noqa: E402

MODULES = [toolchain, containers, project]


def _emit(results) -> tuple[int, int]:
    fails = warns = 0
    for r in results:
        detail = f"  {dim(r.detail)}" if r.detail else ""
        print(f"  [{paint(r.status)}] {r.name}{detail}")
        if r.status is Status.FAIL:
            fails += 1
        elif r.status is Status.WARN:
            warns += 1
        for i, fix in enumerate(r.fixes):
            bullet = "->" if i == 0 else "  "
            print(f"          {dim(bullet)} {fix}")
    return fails, warns


def main() -> int:
    ap = argparse.ArgumentParser(description="Check local dev prerequisites.")
    ap.add_argument("repo_root", help="path to the project repo to check")
    ap.add_argument("--database", default="hello",
                    help="expected DB name in env.sh (default: hello)")
    ap.add_argument("--no-color", action="store_true", help="disable ANSI color")
    args = ap.parse_args()
    if args.no_color:
        set_color(False)

    repo_root = os.path.expanduser(args.repo_root)
    if not os.path.isdir(repo_root):
        ap.error(f"repo path not found: {repo_root}")
    ctx = Context(repo_root=repo_root, database=args.database)

    print("=" * 60)
    print(f" dev24 readiness check  —  {ctx.repo_root}  (db: {ctx.database})")
    print("=" * 60)

    if IS_MAC:
        print(f"\n{preflight.GROUP}")
        pf = preflight.checks(ctx)
        _emit(pf)
        if any(r.status is Status.FAIL for r in pf):
            print("\n" + "=" * 60)
            print(" STOPPED at preflight — bootstrap the toolchain above, then re-run.")
            print("=" * 60)
            return 1

    fails = warns = 0
    for mod in MODULES:
        print(f"\n{mod.GROUP}")
        f, w = _emit(mod.checks(ctx))
        fails += f
        warns += w

    print("\n" + "=" * 60)
    if fails == 0:
        msg = "READY" if warns == 0 else f"READY with {warns} warning(s)"
        print(f" {msg} — {ctx.repo_root} is set up for development.")
    else:
        print(f" {fails} failure(s), {warns} warning(s) — review the '->' steps above.")
        print(" Apply the fixes, then re-run this check.")
    print("=" * 60)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())

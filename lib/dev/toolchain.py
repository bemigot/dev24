"""Toolchain checks: the compilers/runtimes the build and e2e suite need.

Mirrors check-prerequisites.bat (Java/Node/npm/Git) and adds the Linux-relevant
extras the e2e run needs (Python for the validators, Cargo for platform24-bff).
"""
from __future__ import annotations

import os

from .core import (
    IS_MAC, IS_WIN, Context, Result, Status, first_int, pixi_env_python, run, which,
)

GROUP = "Toolchain"

# Hardcoded, project-specific repo layout.
# TODO(revise): the Rust backend-for-frontend dir/binary name is baked in; make it
# configurable (or discovered) rather than tied to this project's structure.
BFF_DIR = "platform24-bff"   # dir under repo_root; the prebuilt binary shares the name

# Versions per docs/onboarding.md §1.
JDK_OK = {21, 25, 26}
NODE_MIN = 22
NPM_MIN = 10
PY_MIN = (3, 10)      # build runs on 3.10+, 3.12 recommended
PY_RECOMMENDED = (3, 12)


def _with_mise_install(fixes: list[str]) -> list[str]:
    """Prepend a platform-specific 'install mise' step when mise is absent.

    The recommended `mise use …` lines below are dead until mise itself exists,
    so when a component is missing AND mise isn't on PATH we lead with how to get
    it. If mise is already installed this adds nothing (the user just runs the
    `mise use` line). Only called on the missing/FAIL path — not for a present-
    but-wrong-version WARN, where the toolchain manager is already in play.
    """
    if which("mise"):
        return fixes
    if IS_MAC:
        install = "install mise: brew install mise"
    elif IS_WIN:
        install = "install mise: winget install jdx.mise"
    else:
        install = "install mise: curl https://mise.run | sh"
    return [install, *fixes]


def _jdk_install_fixes() -> list[str]:
    # mise is the repo's cross-platform toolchain manager (same recipe on
    # macOS/Linux/Windows — Windows already uses it via scripts/helper.ps1). On
    # macOS, brew is offered as a no-extra-tool fallback.
    fixes = ["mise use -g java@temurin-25   (via mise — cross-platform; https://mise.jdx.dev)"]
    if IS_MAC:
        fixes.append("or: brew install openjdk@25")
    return fixes


def _mise_inactive_java() -> str | None:
    """Path to a mise-managed javac that's installed but not on PATH here.

    `mise which javac` resolves the tool from mise's config independently of
    whether mise is activated in the current shell, so it tells installed-but-
    inactive apart from genuinely-absent. None if mise has no Java configured.
    """
    if not which("mise"):
        return None
    rc, out = run(["mise", "which", "javac"])
    path = out.strip()
    if rc == 0 and path.startswith("/") and os.path.exists(path):
        return path
    return None


def _mise_activate_fixes() -> list[str]:
    shell = os.path.basename(os.environ.get("SHELL") or "") or "zsh"
    if shell == "fish":
        activate, rc = "mise activate fish | source", "~/.config/fish/config.fish"
    else:
        if shell not in ("zsh", "bash"):
            shell = "zsh"
        activate = f'eval "$(mise activate {shell})"'
        rc = "~/.zshrc" if shell == "zsh" else "~/.bashrc"
    return [
        f"activate mise in this shell: {activate}",
        f"persist it: add that line to {rc}, then open a new terminal",
    ]


def _java() -> Result:
    # Gate on javac, not java: the build needs a compiler (a JRE is not enough).
    javac = which("javac")
    out = run(["javac", "-version"])[1] if javac else ""
    # macOS ships a /usr/bin/javac stub that exists even with no JDK installed;
    # invoking it prints this and exits non-zero, so which() is fooled.
    is_stub = "Unable to locate a Java Runtime" in out or "No Java runtime" in out

    if javac and not is_stub:
        major = first_int(out)
        if major in JDK_OK:
            return Result.ok("Java JDK (javac)", out.strip())
        return Result.warn(
            "Java JDK (javac)",
            f"{out.strip()} — expected 21, 25, or 26 (CI builds on 25)",
            fixes=_jdk_install_fixes(),
        )

    # No usable javac on PATH (missing, or just the macOS stub). Before declaring
    # the JDK absent, check whether mise has one installed that simply isn't
    # active in this shell — a common state right after `mise use -g java@…`.
    if _mise_inactive_java():
        return Result.fail(
            "Java JDK (javac)",
            "JDK installed via mise but not active in this shell",
            fixes=_mise_activate_fixes(),
        )
    detail = ("only the macOS javac stub is present — no JDK installed" if is_stub
              else "javac not found — a JDK is required to build")
    return Result.fail("Java JDK (javac)", detail,
                       fixes=_with_mise_install(_jdk_install_fixes()))


def _node() -> Result:
    if not which("node"):
        return Result.fail(
            "Node.js",
            "node not found on PATH",
            fixes=_with_mise_install([
                "mise use -g node@lts   (via mise — cross-platform)",
                "or install Node LTS from https://nodejs.org/",
            ]),
        )
    _, out = run(["node", "-v"])
    major = first_int(out)
    if major is not None and major >= NODE_MIN:
        return Result.ok("Node.js", out.strip())
    return Result.warn(
        "Node.js",
        f"{out.strip()} — need v{NODE_MIN}+",
        fixes=["mise use -g node@lts", "or upgrade via your existing Node version manager"],
    )


def _npm() -> Result:
    if not which("npm"):
        return Result.fail("npm", "npm not found (ships with Node.js)",
                           fixes=["reinstall Node.js (npm comes bundled)"])
    _, out = run(["npm", "-v"])
    major = first_int(out)
    if major is not None and major >= NPM_MIN:
        return Result.ok("npm", out.strip())
    return Result.warn("npm", f"{out.strip()} — need v{NPM_MIN}+",
                       fixes=["npm install -g npm@latest"])


def _git() -> Result:
    if not which("git"):
        fix = "brew install git" if IS_MAC else "sudo apt install git"
        # macOS also offers git via the Xcode Command Line Tools.
        fixes = [fix, "or: xcode-select --install"] if IS_MAC else [fix]
        return Result.fail("Git", "git not found on PATH", fixes=fixes)
    _, out = run(["git", "--version"])
    return Result.ok("Git", out.strip())


def _python() -> Result:
    if IS_WIN:
        return _python_windows()
    rc, out = run(["python3", "--version"])
    if rc != 0:
        fix = "brew install python" if IS_MAC else "sudo apt install python3 python3-pip"
        return Result.fail("Python 3", "python3 not found", fixes=[fix])
    parts = out.split()[-1].split(".")
    try:
        ver = (int(parts[0]), int(parts[1]))
    except (ValueError, IndexError):
        ver = None
    if ver and ver >= PY_MIN:
        note = "" if ver >= PY_RECOMMENDED else "  (3.12 recommended)"
        return Result.ok("Python 3", out.strip() + note)
    fix = "brew install python@3.12" if IS_MAC else "sudo apt install python3.12 python3.12-venv"
    return Result.warn("Python 3", f"{out.strip()} — need 3.10+ (3.12 recommended)",
                       fixes=[fix])


# --- Windows: 'py' finds the interpreter; python/python3 may not resolve ------

def _resolves_to_real(cmd: str) -> bool:
    """True if `cmd` runs a real interpreter (not missing, not the Store stub)."""
    if not which(cmd):
        return False
    rc, out = run([cmd, "-c", "import sys; print(sys.executable)"])
    return rc == 0 and bool(out.strip())


def _prepend_user_path_win(directory: str) -> bool:
    """Prepend `directory` to the user PATH (HKCU\\Environment), idempotently."""
    import winreg  # Windows-only stdlib; imported lazily
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment", 0,
                            winreg.KEY_READ | winreg.KEY_WRITE) as key:
            try:
                cur, typ = winreg.QueryValueEx(key, "Path")
            except FileNotFoundError:
                cur, typ = "", winreg.REG_EXPAND_SZ
            parts = [p for p in cur.split(os.pathsep) if p]
            if any(os.path.normcase(p) == os.path.normcase(directory) for p in parts):
                return True
            winreg.SetValueEx(key, "Path", 0, typ or winreg.REG_EXPAND_SZ,
                              os.pathsep.join([directory] + parts))
    except OSError as e:
        print(f"          could not update user PATH: {e}")
        return False
    try:  # tell running shells the environment changed; new processes pick it up
        import ctypes
        ctypes.windll.user32.SendMessageTimeoutW(
            0xFFFF, 0x1A, 0, "Environment", 0x0002, 5000,
            ctypes.byref(ctypes.c_ulong()))
    except Exception:
        pass
    return True


def _fix_win_python_cmds(exe: str) -> bool:
    """Make `python`/`python3` resolve to `exe`: drop a python3.exe beside it (so
    its DLLs/stdlib resolve) and prepend its dir to PATH (ahead of any stub)."""
    import shutil
    d = os.path.dirname(exe)
    py3 = os.path.join(d, "python3.exe")
    try:
        if not os.path.isfile(py3):
            shutil.copy2(exe, py3)
    except OSError as e:
        print(f"          could not create python3.exe: {e}")
        return False
    return _prepend_user_path_win(d)


def _python_windows() -> Result:
    rc, out = run(["py", "-c", "import sys;"
                   " print('%d.%d.%d' % sys.version_info[:3]); print(sys.executable)"])
    if rc != 0 or not out.strip():
        return Result.fail(
            "Python 3", "no Python found (the 'py' launcher is absent)",
            fixes=["powershell -ExecutionPolicy Bypass -File ubootstrap.ps1",
                   "or: winget install 9NQ7512CXL7T   # Python Install Manager"],
        )
    lines = out.strip().splitlines()
    verstr, exe = lines[0], lines[-1]
    try:
        ver = tuple(int(n) for n in verstr.split(".")[:2])
    except ValueError:
        ver = None
    if ver and ver < PY_MIN:
        return Result.warn(
            "Python 3", f"py -> {verstr} — need 3.10+ (3.12 recommended)",
            fixes=["winget install 9NQ7512CXL7T   # newer Python via the manager"])
    missing = [c for c in ("python", "python3") if not _resolves_to_real(c)]
    if not missing:
        return Result.ok("Python 3", f"{verstr} (py, python, python3)")
    return Result.warn(
        "Python 3",
        f"{verstr} via 'py', but {' and '.join(missing)} do not resolve",
        fixes=[f"create python3.exe in {os.path.dirname(exe)} and prepend it to PATH"],
        fix=lambda: _fix_win_python_cmds(exe),
    )


def _pixi(ctx: Context) -> Result:
    # Preferred manager for the scripts/ Python env (scripts/pixi.toml).
    if not which("pixi"):
        fixes = ["curl -fsSL https://pixi.sh/install.sh | bash",
                 "or see https://pixi.sh/latest/#installation"]
        if IS_MAC:
            fixes.insert(0, "brew install pixi")
        return Result.warn(
            "pixi",
            "not found — recommended for the scripts/ Python env (pip3 is the fallback)",
            fixes=fixes,
        )
    rc, out = run(["pixi", "--version"])
    if rc != 0:
        return Result.fail("pixi", f"on PATH but not runnable: {out.strip()[:60]}",
                           fixes=["reinstall: curl -fsSL https://pixi.sh/install.sh | bash"])
    # pixi on PATH ≠ the scripts/ env exists. Until `pixi install` creates it, the
    # env supplies no Python/deps and project._e2e_python falls back to system python3.
    if pixi_env_python(ctx.repo_root) is None:
        return Result.warn(
            "pixi", f"{out.strip()} — but the scripts/ env isn't created yet",
            fixes=["cd scripts && pixi install   # creates .pixi/ with Python + e2e deps"],
        )
    return Result.ok("pixi", f"{out.strip()} (scripts/ env ready)")


def _pip3() -> Result:
    # Only checked as the install fallback when pixi is unavailable.
    if not which("pip3"):
        install = "brew install python" if IS_MAC else "sudo apt install python3-pip"
        return Result.warn("pip3", "not found — needed as the install fallback (no pixi)",
                           fixes=[install, "or install pixi instead"])
    rc, out = run(["pip3", "--version"])
    if rc != 0:
        return Result.warn("pip3", f"on PATH but not runnable: {out.strip()[:60]}")
    return Result.ok("pip3", out.strip())


def _cargo(ctx: Context) -> Result:
    # run-f4.sh starts the bff: needs either a prebuilt binary or cargo.
    binary = os.path.join(ctx.repo_root, BFF_DIR, "target", "release", BFF_DIR)
    if os.path.isfile(binary) and os.access(binary, os.X_OK):
        return Result.ok("Rust/Cargo (bff)", f"prebuilt {BFF_DIR} binary present")
    if which("cargo"):
        _, out = run(["cargo", "--version"])
        return Result.ok("Rust/Cargo (bff)", out.strip())
    second = "or: brew install rust" if IS_MAC else "or: sudo apt install cargo"
    return Result.fail(
        "Rust/Cargo (bff)",
        f"no cargo and no prebuilt {BFF_DIR} binary — run-f4.sh exits 127",
        fixes=[
            "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh",
            second,
        ],
    )


def checks(ctx: Context) -> list[Result]:
    results = [_java(), _node(), _npm(), _git()]
    pixi = _pixi(ctx)
    if pixi.status is Status.OK:
        # On the pixi path the env supplies Python (pinned in scripts/pixi.toml),
        # so the system python3 / pip3 are irrelevant — don't report them.
        results.append(pixi)
    else:
        # On macOS the preflight gate already vetted (and reported) the system
        # Python at the stricter 3.12 floor, so skip the duplicate line here.
        results += ([] if IS_MAC else [_python()]) + [pixi, _pip3()]
    results.append(_cargo(ctx))
    return results

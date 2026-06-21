"""Docker + Postgres checks.

run-f4.sh only needs *something* serving Postgres on localhost:5432 (creds
postgres/postgres) - it never touches a container by name. So the Postgres check
is a plain TCP port probe; the documented `p24-postgres` container is only a
recommended way to provide it (docs/onboarding.md §2), surfaced in the fix text.
"""
from __future__ import annotations

import socket

from .core import IS_MAC, Context, Result, first_int, run, which

GROUP = "Docker / Postgres"

CONTAINER = "p24-postgres"
DOCKER_MIN = 20  # docs/onboarding.md §1


def _docker_missing_fixes() -> list[str]:
    # On macOS the docker CLI is a separate Homebrew formula from the engine -
    # colima can be installed and still leave no `docker` on PATH (the user's
    # "colima but no docker shortcuts" case). Install the client, then the engine.
    if IS_MAC:
        if which("colima"):
            return [
                "brew install docker docker-compose   # colima is here; you just need the CLI",
                "then start the engine: colima start",
            ]
        return [
            "brew install colima docker docker-compose",
            "then: colima start   (or use Docker Desktop instead)",
        ]
    return [
        "sudo apt install docker.io && sudo usermod -aG docker $USER",
        "or follow https://docs.docker.com/engine/install/",
    ]


def _docker_unreachable_fixes() -> list[str]:
    # Daemon not responding. macOS has no system docker service - the engine is a
    # VM managed by colima (or Docker Desktop), so `systemctl` does not apply.
    if IS_MAC:
        if which("colima"):
            return [
                "colima start   (the colima VM is not running)",
                "check it with: colima status",
            ]
        return [
            "start Docker Desktop, or install colima: brew install colima && colima start",
        ]
    return [
        "sudo systemctl start docker",
        "or add yourself to the docker group: sudo usermod -aG docker $USER (re-login)",
    ]


def _docker() -> Result:
    if not which("docker"):
        return Result.fail("Docker engine", "docker not found on PATH",
                           fixes=_docker_missing_fixes())
    rc, out = run(["docker", "info", "--format", "{{.ServerVersion}}"])
    if rc != 0:
        return Result.fail("Docker engine", "docker installed but daemon not reachable",
                           fixes=_docker_unreachable_fixes())
    version = out.strip()
    major = first_int(version)
    if major is not None and major < DOCKER_MIN:
        return Result.warn("Docker engine", f"server {version} - need {DOCKER_MIN}+",
                           fixes=["upgrade per https://docs.docker.com/engine/install/"])
    return Result.ok("Docker engine", f"server {version}")


def _port_open(host: str, port: int, timeout: float = 1.0) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def _postgres(ctx: Context) -> Result:
    # The only thing that matters to run-f4.sh: is Postgres reachable on :5432?
    if _port_open("localhost", 5432):
        return Result.ok("Postgres :5432", "reachable")

    docker_run = (
        f"docker run -d --name {CONTAINER} -e POSTGRES_USER=postgres "
        f"-e POSTGRES_PASSWORD=postgres -e POSTGRES_DB={ctx.database} "
        f"-p 5432:5432 postgres:17-alpine"
    )
    fixes = []
    # If the documented container exists but is stopped, starting it is the quick fix.
    if which("docker"):
        rc, out = run(["docker", "ps", "-a", "--filter", f"name=^/{CONTAINER}$",
                       "--format", "{{.Status}}"])
        if rc == 0 and out.strip():
            fixes.append(f"docker start {CONTAINER}")
    fixes.append(docker_run)
    return Result.fail("Postgres :5432", "nothing listening on localhost:5432", fixes=fixes)


def checks(ctx: Context) -> list[Result]:
    return [_docker(), _postgres(ctx)]

#!/usr/bin/env bash
# Build + run an Ubuntu sandbox to test/debug
# check-req.py as an UNPRIVILEGED user, with the checker code and a
# target project bind-mounted.
#
#   ./run.sh              # open an interactive shell in the sandbox
#   ./run.sh check [...]  # run check-req.py /opt/project once, then exit
#                         #   extra args pass through, e.g.:
#                         #   ./run.sh check --no-color --solution murabex
#
# UBUNTU_VERSION picks the base release (default 26.04); the image is tagged
# per-version so variants coexist:
#   UBUNTU_VERSION=20.04 ./run.sh check
#
# Mounts (both read-only):
#   $SCRIPTS  -> /opt/scripts   (check-req.py + lib/; you edit these on the HOST)
#   $PROJECT  -> /opt/project   (the repo_root being checked)
#
# Because the mounts are live, edit *.py on the HOST and immediately re-run in
# the container (no rebuild). To check the dev24 fixture instead:
#   PROJECT=~/p/dev24/sample-project ./run.sh check
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="${SCRIPTS:-$HOME/e/p24core/scripts}"   # the checker code under test
PROJECT="${PROJECT:-$HOME/e/p24core}"           # target repo_root to inspect
UBUNTU_VERSION="${UBUNTU_VERSION:-26.04}"       # base release (see Dockerfile ARG)
IMAGE="dev24-ubuntu${UBUNTU_VERSION//./}"       # e.g. dev24-ubuntu2604

for d in "$SCRIPTS" "$PROJECT"; do
  [[ -d "$d" ]] || { echo "not found: $d" >&2; exit 1; }
done
[[ -f "$SCRIPTS/check-req.py" ]] || { echo "no check-req.py in $SCRIPTS" >&2; exit 1; }

# Build is a no-op after the first run unless the Dockerfile changes.
docker build --build-arg "UBUNTU_VERSION=$UBUNTU_VERSION" -t "$IMAGE" "$HERE"

# Mount read-only by default (protects the host tree; the checker only reports
# unless you opt into fixes). Drop ':ro' on /opt/project to test project-local
# fixers that write into repo_root.
common=(
  --rm
  -v "$SCRIPTS:/opt/scripts:ro"
  -v "$PROJECT:/opt/project:ro"
  -w /opt
  "$IMAGE"
)

# Allocate a TTY only when one is attached, so `check` works in pipes/CI too.
tty=(); [[ -t 0 && -t 1 ]] && tty=(-it)

if [[ "${1:-}" == "check" ]]; then
  shift
  exec docker run "${tty[@]}" "${common[@]}" python3 /opt/scripts/check-req.py /opt/project "$@"
fi

exec docker run -it "${common[@]}" bash

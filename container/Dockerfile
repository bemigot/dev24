# Ubuntu sandbox for exercising check-req.py as an
# UNPRIVILEGED user against a target project.
#
# The image carries "system default" python3 + curl. The checker code and the target project are
# bind-mounted at run time (see container/run.sh), so host edits are live —
# no rebuild needed to test a change.
#
# UBUNTU_VERSION selects the base release (single source for every variant):
#   docker build .                                  # default: 26.04
#   docker build --build-arg UBUNTU_VERSION=20.04 . # legacy target
ARG UBUNTU_VERSION=26.04
FROM ubuntu:${UBUNTU_VERSION}

# Every supported Ubuntu ships a python3 new enough for the stdlib-only checker.
# DEBIAN_FRONTEND keeps apt non-interactive; clean lists to keep the image small.
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    python3 \
    curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Unprivileged user. UID/GID are build args so they can be matched to the host
# owner of the bind mounts when that matters (Linux hosts); the defaults are
# fine on macOS/Windows where the file-sharing layer handles ownership.
ARG UID=3000
ARG GID=3000
RUN groupadd -g "${GID}" dev \
 && useradd -m -u "${UID}" -g "${GID}" -s /bin/bash dev

RUN printf '%s\n' \
    'Pixi setup:' \
    '  curl -fsSL https://pixi.sh/install.sh | sh' \
    '  echo '\''PATH="$HOME/.pixi/bin:$PATH"'\'' >> ~/.bashrc' \
    '  . ~/.bashrc' \
    > /opt/Readme

USER dev
WORKDIR /opt
CMD ["bash", "-c", "cat Readme; exec bash"]

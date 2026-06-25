# Ubuntu sandbox for exercising check-req.py as an
# UNPRIVILEGED user against a target project.
#
# The checker is stdlib-only (see CLAUDE.md), so the image carries nothing but
# python3 + a non-root user. The checker code and the target project are
# bind-mounted at run time (see container/run.sh), so host edits are live —
# no rebuild needed to test a change.
FROM ubuntu:20.04

# Ubuntu 20.04 ships Python 3.8; the checker needs only the stdlib.
# DEBIAN_FRONTEND keeps apt non-interactive; clean lists to keep the image small.
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    python3 curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Unprivileged user. UID/GID are build args so they can be matched to the host
# owner of the bind mounts when that matters (Linux hosts); the defaults are
# fine on macOS/Windows where the file-sharing layer handles ownership.
ARG UID=3000
ARG GID=3000
RUN groupadd -g "${GID}" dev \
 && useradd -m -u "${UID}" -g "${GID}" -s /bin/bash dev

USER dev
WORKDIR /opt
CMD ["bash"]

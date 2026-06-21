#!/usr/bin/env bash
#
# get-virtio-iso.sh — download the virtio-win driver ISO and verify it against
# a checksum we pin in git.
#
# Windows Setup needs these paravirtualized drivers to see the virtio disk/net
# during the golden-image mint, and the libvirt harness uses virtio devices too.
# quickget is supposed to fetch this ISO but its source occasionally serves an
# anti-bot HTML page instead (a ~4 KB "Making sure you're not a bot!" file).
#
# Fedora does NOT publish a checksum for the ISO itself — only for the RPMs.
# So virtio-win-<ver>.sha256 here was extracted from the GPG-signed noarch.rpm
# header (RPMTAG_FILEDIGESTS), which bundles this exact ISO. That makes it an
# independent anchor, not a self-hash of whatever we happened to download.
#
# The ISO is large and gitignored; only the .sha256 is committed. Re-run this to
# fetch (or re-verify) the ISO locally.
#
# Usage:
#   ./get-virtio-iso.sh [DEST]
#
#   DEST defaults to <script dir>/virtio-win-0.1.285.iso. quickemu mounts its
#   copy at quickemu/windows-11/virtio-win.iso — symlink or copy this there.

set -euo pipefail

VERSION="0.1.285"
ISO="virtio-win-${VERSION}.iso"
# Versioned archive path is immutable, so it always matches the pinned checksum.
# (stable-virtio/ moves to new versions and would drift from the .sha256.)
URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-${VERSION}-1/${ISO}"

HERE="$(cd "$(dirname "$0")" && pwd)"
SHA_FILE="$HERE/virtio-win-${VERSION}.sha256"
DEST="${1:-$HERE/$ISO}"

if [ ! -f "$SHA_FILE" ]; then
  echo "ERROR: checksum file missing: $SHA_FILE" >&2
  exit 1
fi
EXPECTED="$(awk '{print $1; exit}' "$SHA_FILE")"

verify() {  # $1 = file ; returns 0 if its sha256 matches EXPECTED
  local got
  got="$(sha256sum "$1" | awk '{print $1}')"
  [ "$got" = "$EXPECTED" ]
}

if [ -f "$DEST" ] && verify "$DEST"; then
  echo "==> $DEST already present and verified — nothing to do."
  exit 0
fi

TMP="$DEST.partial"
echo "==> Downloading $ISO ..."
echo "    $URL"
if command -v curl >/dev/null 2>&1; then
  curl -fL --retry 3 -o "$TMP" "$URL"
elif command -v wget >/dev/null 2>&1; then
  wget -O "$TMP" "$URL"
else
  echo "ERROR: need curl or wget to download." >&2
  exit 1
fi

echo "==> Verifying SHA256 against $SHA_FILE ..."
if ! verify "$TMP"; then
  echo "ERROR: checksum mismatch — refusing to install a bad ISO." >&2
  echo "       expected: $EXPECTED" >&2
  echo "       got:      $(sha256sum "$TMP" | awk '{print $1}')" >&2
  echo "       (likely an anti-bot HTML page or a truncated/corrupt download;" >&2
  echo "        left at $TMP for inspection)" >&2
  exit 1
fi

mv "$TMP" "$DEST"
echo "    OK — $DEST"
echo
echo "To use it with quickemu, point its copy at this file, e.g.:"
echo "    ln -sf \"$DEST\" \"$HERE/quickemu/windows-11/virtio-win.iso\""

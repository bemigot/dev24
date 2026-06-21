#!/usr/bin/env bash
#
# make-unattended-iso.sh — (re)build the Windows unattended answer disk from the
# version-controlled answer file in VM/unattended/, instead of the throwaway
# copy quickget drops in the VM dir.
#
# Why this exists: quickget generates windows-11/unattended/autounattend.xml and
# packs it into windows-11/unattended.iso, but its answer file has no
# Microsoft-Windows-International-Core-WinPE component — so Windows Setup stalls
# on the first "Select language settings" screen and the install is not actually
# hands-free. VM/unattended/autounattend.xml is that file with the missing
# component added; this script rebuilds the ISO from it (pulling in the SPICE
# guest-agent MSIs that quickget downloaded into the VM dir, if present).
#
# Run AFTER `quickget windows 11` and BEFORE `quickemu`, with no VM running off
# the ISO. mkisofs comes from the `genisoimage` package (see setup-host.sh).
#
# UNTESTED: not yet validated through a full mint — the golden image built
# 2026-06-20 14:44 used quickget's original unattended.iso with the language
# screen answered by hand. Confirm the language screen is skipped before relying
# on this.
#
# Usage:
#   ./make-unattended-iso.sh [VMDIR]
#     VMDIR defaults to quickemu/windows-11 (relative to this script).

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC_XML="$HERE/unattended/autounattend.xml"
VMDIR="${1:-$HERE/quickemu/windows-11}"
VMNAME="$(basename "$VMDIR")"
OUT="$VMDIR/unattended.iso"

command -v mkisofs >/dev/null 2>&1 || {
  echo "ERROR: mkisofs not found — 'sudo apt install genisoimage'." >&2; exit 1; }
[ -f "$SRC_XML" ] || { echo "ERROR: missing answer file: $SRC_XML" >&2; exit 1; }
[ -d "$VMDIR" ]   || { echo "ERROR: VM dir not found: $VMDIR (run quickget first)" >&2; exit 1; }

# Don't clobber an ISO a running VM may have mounted.
if [ -e "$VMDIR/.lock" ] || pgrep -af "$VMNAME/disk.qcow2" >/dev/null 2>&1; then
  echo "ERROR: a VM appears to be running in $VMDIR — shut it down first" >&2
  echo "       (./quickemu --vm ${VMNAME}.conf --kill), then re-run." >&2
  exit 1
fi

# Stage our answer file plus quickget's SPICE MSIs (optional — only used by the
# oobeSystem guest-agent install steps; the language/disk automation works
# without them).
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp "$SRC_XML" "$STAGE/autounattend.xml"

shopt -s nullglob
msis=("$VMDIR/unattended/"*.msi)
if [ ${#msis[@]} -gt 0 ]; then
  cp "${msis[@]}" "$STAGE/"
  echo "==> Including ${#msis[@]} SPICE MSI(s) from $VMDIR/unattended/."
else
  echo "==> No SPICE MSIs in $VMDIR/unattended/ — building an XML-only ISO."
fi

echo "==> Building $OUT ..."
mkisofs -quiet -J -o "$OUT" "$STAGE/"
echo "    done — $(stat -c%s "$OUT") bytes. quickemu will attach it at cdrom index=2."

#!/usr/bin/env bash
#
# setup-host.sh — one-time host setup for the dev24 Windows VM harness.
#
# Installs the KVM/libvirt stack, enables libvirt's default NAT network, grants
# the current user VM access, and creates the image directory the harness uses.
# Run this once on the host (pug.lan); afterwards `VM/harness.py` and the golden
# image mint steps in README.md can run.
#
# Requires sudo (apt + systemctl + group + /opt). Re-running is safe — apt and
# the mkdir/usermod steps are idempotent.
#
# Debian/Ubuntu only. Adjust package names for other distros.

set -euo pipefail

IMAGE_DIR="${DEV24_VM_IMAGE_DIR:-/opt/dev24-vm}"   # keep in sync with harness.py

echo "==> Installing virtualization stack (qemu / libvirt / ovmf / swtpm) ..."
sudo apt update
sudo apt install -y \
  qemu-system-x86 qemu-utils \
  libvirt-daemon-system libvirt-clients virtinst \
  ovmf swtpm \
  python3-libvirt \
  virt-viewer

echo "==> Enabling libvirt and the default NAT network ..."
sudo systemctl enable --now libvirtd
sudo virsh net-autostart default
sudo virsh net-start default 2>/dev/null || true   # already-active is fine

echo "==> Granting $USER access to libvirt and kvm ..."
sudo usermod -aG libvirt,kvm "$USER"

if [ -d "$IMAGE_DIR" ]; then
  echo "==> Image directory $IMAGE_DIR already exists — leaving it as is."
else
  read -r -p "==> Create image directory $IMAGE_DIR? [y/N] " reply
  case "$reply" in
    [Yy]*)
      sudo mkdir -p "$IMAGE_DIR"
      sudo chown "$USER":"$USER" "$IMAGE_DIR"
      echo "    created and chowned to $USER."
      ;;
    *)
      echo "    skipped — create it yourself before minting the golden image."
      ;;
  esac
fi

echo
echo "Done. Two follow-ups:"
echo "  1. Group change needs a new login to take effect — log out/in,"
echo "     or start a fresh session with: newgrp libvirt"
echo "  2. Mint the golden image into $IMAGE_DIR/golden-win.qcow2"
echo "     (see VM/README.md — 'Building the golden image')."

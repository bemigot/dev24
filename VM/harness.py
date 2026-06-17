#!/usr/bin/env python3
"""Ephemeral Windows VM harness for testing check-req.py.

Creates a disposable overlay on top of a golden qcow2 image, boots it,
runs a command via SSH, then tears it down.

Usage:
    python3 vm/harness.py run
    python3 vm/harness.py shell
    python3 vm/harness.py teardown
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

# Image locations. Override IMAGE_DIR (e.g. DEV24_VM_IMAGE_DIR) or edit here as
# needed; win-vm.xml's disk path is patched at runtime from OVERLAY_IMAGE.
IMAGE_DIR = os.environ.get("DEV24_VM_IMAGE_DIR", "/opt/dev24-vm")
GOLDEN_IMAGE = os.path.join(IMAGE_DIR, "golden-win.qcow2")
OVERLAY_IMAGE = os.path.join(IMAGE_DIR, "run-overlay.qcow2")
DOMAIN_XML = os.path.join(os.path.dirname(__file__), "win-vm.xml")
DOMAIN_NAME = "dev24-win-test"
SSH_USER = "dev"
SSH_TIMEOUT = 120  # seconds to wait for SSH to become available


def _run(cmd: list[str], check=True) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, check=check, capture_output=True, text=True)


def create_overlay():
    if os.path.exists(OVERLAY_IMAGE):
        os.remove(OVERLAY_IMAGE)
    _run(["qemu-img", "create", "-f", "qcow2",
          "-b", GOLDEN_IMAGE, "-F", "qcow2", OVERLAY_IMAGE])
    print(f"Overlay created: {OVERLAY_IMAGE}")


def define_and_start():
    # Inject overlay path into domain XML
    tree = ET.parse(DOMAIN_XML)
    for disk in tree.findall(".//disk[@type='file']"):
        source = disk.find("source")
        if source is not None:
            source.set("file", OVERLAY_IMAGE)
    xml_str = ET.tostring(tree.getroot(), encoding="unicode")

    import libvirt
    conn = libvirt.open("qemu:///system")
    dom = conn.defineXML(xml_str)
    dom.create()
    print(f"VM '{DOMAIN_NAME}' started")
    return conn, dom


def wait_for_ssh(ip: str) -> bool:
    import socket
    deadline = time.time() + SSH_TIMEOUT
    while time.time() < deadline:
        try:
            with socket.create_connection((ip, 22), timeout=2):
                return True
        except OSError:
            time.sleep(3)
    return False


def get_ip(dom) -> str | None:
    """Poll virsh domifaddr until an IP appears."""
    deadline = time.time() + 60
    while time.time() < deadline:
        result = _run(["virsh", "domifaddr", DOMAIN_NAME], check=False)
        for line in result.stdout.splitlines():
            parts = line.split()
            for part in parts:
                if "." in part and "/" in part:
                    return part.split("/")[0]
        time.sleep(3)
    return None


def ssh(ip: str, cmd: str) -> int:
    return subprocess.call([
        "ssh", "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        f"{SSH_USER}@{ip}", cmd,
    ])


def teardown(conn=None, dom=None):
    import libvirt
    conn = conn or libvirt.open("qemu:///system")
    try:
        dom = dom or conn.lookupByName(DOMAIN_NAME)
        try:
            dom.destroy()
        except libvirt.libvirtError:
            pass
        dom.undefine()
        print(f"VM '{DOMAIN_NAME}' destroyed and undefined")
    except libvirt.libvirtError:
        print("No running VM found")
    if os.path.exists(OVERLAY_IMAGE):
        os.remove(OVERLAY_IMAGE)
        print("Overlay removed")


def cmd_run():
    create_overlay()
    conn, dom = define_and_start()
    ip = get_ip(dom)
    if not ip:
        print("ERROR: could not get VM IP", file=sys.stderr)
        teardown(conn, dom)
        return 1
    print(f"VM IP: {ip}")
    if not wait_for_ssh(ip):
        print("ERROR: SSH did not become available", file=sys.stderr)
        teardown(conn, dom)
        return 1
    rc = ssh(ip, "cd dev24 && git pull && python3 check-req.py --no-color")
    teardown(conn, dom)
    return rc


def cmd_shell():
    create_overlay()
    conn, dom = define_and_start()
    ip = get_ip(dom)
    if not ip:
        print("ERROR: could not get VM IP", file=sys.stderr)
        teardown(conn, dom)
        return 1
    print(f"VM IP: {ip}  —  type 'exit' to shut down and discard the VM")
    wait_for_ssh(ip)
    subprocess.call(["ssh", "-o", "StrictHostKeyChecking=no",
                     "-o", "UserKnownHostsFile=/dev/null",
                     f"{SSH_USER}@{ip}"])
    teardown(conn, dom)
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("command", choices=["run", "shell", "teardown"])
    args = ap.parse_args()

    if args.command == "run":
        sys.exit(cmd_run())
    elif args.command == "shell":
        sys.exit(cmd_shell())
    elif args.command == "teardown":
        teardown()


if __name__ == "__main__":
    main()

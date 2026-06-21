#!/usr/bin/python3
"""Bring up a bare Windows VM for hands-on check-req.py testing.

See VM/SPEC.md. golden.qcow2 is a pristine, read-only base; each bring-up runs a
persistent overlay (go1.qcow2) with a freshly built control CD (MAINTCD)
attached. The maintainer drives the VM by hand on the host console.

Run with the system Python (./VM/harness.py uses /usr/bin/python3 via the
shebang; `python3` on PATH may be a pixi env without libvirt).

Usage:
    ./VM/harness.py up        # build CD, boot the VM, leave it running
    ./VM/harness.py down      # graceful shutdown, keep the overlay
    ./VM/harness.py reset     # discard the overlay (next up starts clean)
    ./VM/harness.py teardown  # destroy VM, remove overlay + CD image
    ./VM/harness.py ip        # print the guest's IPv4 (from its DHCP lease)
    ./VM/harness.py ssh [cmd] # ssh in as Quickemu (cboot1.ps1 must have run)
"""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(HERE)

# Image locations. Override IMAGE_DIR via DEV24_VM_IMAGE_DIR; win-vm.xml's disk
# and cdrom paths are patched at runtime from OVERLAY_IMAGE / CONTROL_ISO.
IMAGE_DIR = os.environ.get("DEV24_VM_IMAGE_DIR", "/opt/dev24-vm")
GOLDEN_IMAGE = os.path.join(IMAGE_DIR, "golden.qcow2")
OVERLAY_IMAGE = os.path.join(IMAGE_DIR, "go1.qcow2")
CONTROL_ISO = os.path.join(IMAGE_DIR, "maintcd.iso")

VM_XML = os.path.join(HERE, "win-vm.xml")
VM_NAME = "dev24-win-test"
CD_LABEL = "MAINTCD"
# The account quickget's unattended install creates (in Administrators); cboot1.ps1
# authorizes the host's SSH keys for it.
SSH_USER = "Quickemu"

# Control-CD payload: the scripts in VM/cd/, the checker + lib + a fixture to run
# it against (from the repo), and the maintainer's SSH keys (from the host).
CD_SRC = os.path.join(HERE, "cd")
AUTHORIZED_KEYS = os.path.expanduser("~/.ssh/authorized_keys")
_IGNORE = shutil.ignore_patterns("__pycache__", "*.pyc")


def _run(cmd, check=True):
    return subprocess.run(cmd, check=check, capture_output=True, text=True)


# ---- control CD -----------------------------------------------------------

def build_control_cd():
    if not shutil.which("mkisofs"):
        sys.exit("ERROR: mkisofs not found — 'sudo apt install genisoimage'.")
    if not os.path.isfile(AUTHORIZED_KEYS):
        sys.exit(f"ERROR: {AUTHORIZED_KEYS} not found — needed for cboot1.ps1.")

    with tempfile.TemporaryDirectory() as stage:
        for name in os.listdir(CD_SRC):                 # ubootstrap/cboot1/Readme
            shutil.copy(os.path.join(CD_SRC, name), os.path.join(stage, name))
        shutil.copy(os.path.join(REPO_ROOT, "check-req.py"),
                    os.path.join(stage, "check-req.py"))
        shutil.copytree(os.path.join(REPO_ROOT, "lib"),
                        os.path.join(stage, "lib"), ignore=_IGNORE)
        shutil.copytree(os.path.join(REPO_ROOT, "sample-project"),
                        os.path.join(stage, "sample-project"), ignore=_IGNORE)
        shutil.copy(AUTHORIZED_KEYS, os.path.join(stage, "authorized_keys"))

        os.makedirs(IMAGE_DIR, exist_ok=True)
        _run(["mkisofs", "-quiet", "-J", "-r", "-V", CD_LABEL,
              "-o", CONTROL_ISO, stage])
    print(f"Control CD built: {CONTROL_ISO}  (label {CD_LABEL})")


# ---- images ---------------------------------------------------------------

def ensure_overlay():
    if not os.path.isfile(GOLDEN_IMAGE):
        sys.exit(f"ERROR: golden image not found: {GOLDEN_IMAGE}\n"
                 f"       Mint it first (see VM/README.md).")
    if os.path.isfile(OVERLAY_IMAGE):
        print(f"Overlay exists, reusing: {OVERLAY_IMAGE}")
        return
    _run(["qemu-img", "create", "-f", "qcow2",
          "-b", GOLDEN_IMAGE, "-F", "qcow2", OVERLAY_IMAGE])
    print(f"Overlay created: {OVERLAY_IMAGE}")


# ---- libvirt --------------------------------------------------------------

def _libvirt():
    """Import the system python3-libvirt, or explain why it's missing.

    The `python3` on PATH here is often a pixi env without libvirt; the harness
    needs the distro package. Run it with the system interpreter:
        /usr/bin/python3 VM/harness.py <cmd>   (or ./VM/harness.py — the shebang
        already points there).
    """
    try:
        import libvirt
    except ModuleNotFoundError:
        sys.exit("ERROR: 'libvirt' not importable under this Python "
                 f"({sys.executable}).\n"
                 "       Use the system interpreter: /usr/bin/python3 VM/harness.py …\n"
                 "       (install with: sudo apt install python3-libvirt)")
    # libvirt prints every error to stderr via its default handler; we handle
    # them as exceptions (e.g. the expected lookup miss before first define),
    # so silence the printer.
    libvirt.registerErrorHandler(lambda _ctx, _err: None, None)
    return libvirt


def _connect():
    conn = _libvirt().open("qemu:///system")
    if conn is None:
        sys.exit("ERROR: cannot open qemu:///system")
    return conn


def _lookup(conn):
    try:
        return conn.lookupByName(VM_NAME)
    except _libvirt().libvirtError:
        return None


def _domain_xml(uuid=None):
    """win-vm.xml with the overlay/control-CD paths patched, and — when refreshing
    an existing definition — its UUID injected, so defineXML updates the stored
    domain in place instead of clashing with it (win-vm.xml carries no <uuid>)."""
    tree = ET.parse(VM_XML)
    root = tree.getroot()
    for disk in root.findall(".//disk"):
        source = disk.find("source")
        if source is None:
            continue
        if disk.get("device") == "cdrom":
            source.set("file", CONTROL_ISO)
        elif disk.get("device") == "disk":
            source.set("file", OVERLAY_IMAGE)
    if uuid:
        el = root.find("uuid")
        if el is None:
            el = ET.Element("uuid")
            name = root.find("name")
            root.insert(list(root).index(name) + 1 if name is not None else 0, el)
        el.text = uuid
    return ET.tostring(root, encoding="unicode")


def _running_dom():
    """Return the active VM, or exit with a clear message if it isn't up."""
    dom = _lookup(_connect())
    if not dom or not dom.isActive():
        sys.exit(f"ERROR: '{VM_NAME}' is not running — './VM/harness.py up' first.")
    return dom


def get_ip(dom):
    """The guest's IPv4 address, from libvirt's DHCP lease (ARP as fallback)."""
    lv = _libvirt()
    for src in (lv.VIR_DOMAIN_INTERFACE_ADDRESSES_SRC_LEASE,
                lv.VIR_DOMAIN_INTERFACE_ADDRESSES_SRC_ARP):
        try:
            ifaces = dom.interfaceAddresses(src)
        except lv.libvirtError:
            continue
        for info in (ifaces or {}).values():
            for addr in info.get("addrs") or []:
                if addr.get("type") == lv.VIR_IP_ADDR_TYPE_IPV4:
                    return addr["addr"]
    return None


# ---- commands -------------------------------------------------------------

def cmd_up():
    build_control_cd()
    ensure_overlay()
    conn = _connect()
    dom = _lookup(conn)
    if dom and dom.isActive():
        print(f"VM '{VM_NAME}' already running.")
        return 0
    # defineXML creates the domain, or updates an existing inactive definition
    # in place (preserving the UEFI nvram) — reuse its UUID so the redefine
    # matches the stored domain instead of clashing; no undefine needed.
    dom = conn.defineXML(_domain_xml(dom.UUIDString() if dom else None))
    dom.create()
    print(f"VM '{VM_NAME}' started with {CD_LABEL} attached.")
    print("Open the console on the host, e.g.:")
    print(f"    virt-viewer --connect qemu:///system {VM_NAME} 2>/dev/null &")
    print(f"then follow the {CD_LABEL} drive's Readme.md")
    return 0


def cmd_down():
    conn = _connect()
    dom = _lookup(conn)
    if not dom or not dom.isActive():
        print(f"VM '{VM_NAME}' is not running.")
        return 0
    dom.shutdown()                # ACPI graceful; the guest may take a while
    print(f"Requested graceful shutdown of '{VM_NAME}'. Overlay kept.")
    return 0


def cmd_reset():
    conn = _connect()
    dom = _lookup(conn)
    if dom and dom.isActive():
        sys.exit(f"ERROR: '{VM_NAME}' is running — 'harness.py down' first.")
    if os.path.isfile(OVERLAY_IMAGE):
        os.remove(OVERLAY_IMAGE)
        print(f"Overlay discarded: {OVERLAY_IMAGE}")
    else:
        print("No overlay to discard.")
    return 0


def cmd_teardown():
    conn = _connect()
    dom = _lookup(conn)
    if dom:
        try:
            if dom.isActive():
                dom.destroy()
        except _libvirt().libvirtError:
            pass
        # UEFI domain: must remove the nvram too, else undefine refuses.
        dom.undefineFlags(_libvirt().VIR_DOMAIN_UNDEFINE_NVRAM)
        print(f"VM '{VM_NAME}' destroyed and undefined.")
    else:
        print("No VM defined.")
    for path in (OVERLAY_IMAGE, CONTROL_ISO):
        if os.path.isfile(path):
            os.remove(path)
            print(f"Removed {path}")
    return 0


def cmd_ip():
    ip = get_ip(_running_dom())
    if not ip:
        sys.exit("ERROR: no IPv4 lease yet — give the guest a moment, then retry.")
    print(ip)
    return 0


def cmd_ssh(extra):
    ip = get_ip(_running_dom())
    if not ip:
        sys.exit("ERROR: no IPv4 lease yet — give the guest a moment, then retry.")
    # Ephemeral VM: don't pollute/clash known_hosts (the host key changes on reset).
    cmd = ["ssh",
           "-o", "StrictHostKeyChecking=no",
           "-o", "UserKnownHostsFile=/dev/null",
           "-o", "LogLevel=ERROR",
           f"{SSH_USER}@{ip}"] + extra
    print(f"+ ssh {SSH_USER}@{ip} {' '.join(extra)}".rstrip(), file=sys.stderr)
    return subprocess.call(cmd)


def main():
    ap = argparse.ArgumentParser(
        description="Bare Windows VM bring-up (see VM/SPEC.md).")
    ap.add_argument("command",
                    choices=["up", "down", "reset", "teardown", "ip", "ssh"])
    ap.add_argument("args", nargs=argparse.REMAINDER,
                    help="for 'ssh': a remote command to run (default: a shell)")
    args = ap.parse_args()
    if args.command == "ssh":
        return cmd_ssh(args.args)
    return {
        "up": cmd_up,
        "down": cmd_down,
        "reset": cmd_reset,
        "teardown": cmd_teardown,
        "ip": cmd_ip,
    }[args.command]()


if __name__ == "__main__":
    sys.exit(main())

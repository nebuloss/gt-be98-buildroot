#!/usr/bin/env python3
"""Phase 3 ("the inversion") ASUS graft-manifest generator.

Computes the exact set of proprietary files that must be grafted from the
validated ASUS 0031 rootfs blob into a Buildroot-skeleton rootfs, starting
from the KEEP daemons and walking the full DT_NEEDED shared-library closure.

Usage:
    python3 gen-graft-manifest.py <unsquashed-0031-rootfs-dir> > phase3-graft-manifest.txt

Requirements: host binutils `readelf` (parses foreign-arch ELF fine).
The rootfs dir must be a plain `unsquashfs` of the 0031 blob
(sha256 dfbf98b4d3a474887ad029e9e6347da081f013e615a607f4f083bb2f3ab28d2c).

Output sections:
  [seed:*]        the explicit KEEP binaries (tiered)
  [closure]       every shared lib reached via recursive DT_NEEDED
  [link]          symlinks that must be reproduced (lib sonames, rc farm)
  [kmod]          the whole /lib/modules tree (aarch64, version-locked to
                  the prebuilt kernel - grafted as one unit)
  [data]          /rom tree (read-only config: init.d rails, wlan fw+nvram,
                  defaults) + structural top-level files
  [dlopen?]       .so names found in seed/lib strings but NOT in any
                  DT_NEEDED - candidates for runtime dlopen; review by hand.

Design notes:
  - busybox and its applet symlink farm are deliberately NOT in the graft
    set: Buildroot provides busybox.  /bin/bash -> busybox must be
    reproduced by the skeleton (ASUS rail scripts use [[ ]] / bashisms).
  - the rc multicall farm (159 symlinks -> rc) IS grafted, minus the
    entries already stripped by board/gt-be98/rootfs-remove.list.
"""
import hashlib
import os
import re
import subprocess
import sys
from datetime import datetime, timezone

ROOT = os.path.abspath(sys.argv[1])
LIBDIRS = ["lib", "usr/lib", "lib64"]  # /rom/etc/ld.so.conf: /opt/lib /opt/usr/lib /lib /usr/lib (+lib64 for aarch64 helpers)

# ---------------------------------------------------------------- seed sets
SEEDS = {
    # Tier A1 - PID1 + nvram + boot rail control (cannot boot without)
    "seed:core": [
        "/sbin/rc",                 # multicall PID1 (init -> rc), all rc_services
        "/bin/nvram",               # nvram CLI
        "/usr/sbin/envrams",        # envram daemon (boot rail S35 system-config; MAC source)
        "/usr/sbin/envram",         # envram client
        "/bin/bcm_boot_launcher",   # runs /etc/rc3.d S-rail
        "/bin/bcm_bootstate",       # dual-slot commit control (dead-man dependency)
        "/bin/bcm_flasher",         # slot flasher (hnd-write path)
    ],
    # Tier A2 - WiFi bring-up + steady state
    "seed:wifi": [
        "/usr/sbin/hostapd",
        "/usr/sbin/hostapd_cli",
        "/bin/eapd",
        "/usr/sbin/wlceventd",
        "/usr/sbin/wlc_monitor",
        "/sbin/wps_pbcd",
        "/usr/sbin/wl",
        "/usr/sbin/dhd",
        "/usr/sbin/wlconf",
        "/bin/wlaffinity",
        "/usr/sbin/acsd2",          # ACS daemon (acs_disable=1 live, binary kept)
        "/usr/sbin/emf",            # multicast forwarding helpers (wifi.sh rail)
        "/usr/sbin/igs",
    ],
    # Tier A3 - LAN/switch datapath + multicast + accel ctl (rc execs these)
    "seed:net": [
        "/bin/mcpd",
        "/bin/brctl",
        "/bin/ethctl",
        "/bin/ethswctl",
        "/bin/vlanctl",
        "/bin/fcctl",
        "/bin/bcmmcastctl",
        "/bin/archerctl",
        "/bin/tmctl",
        "/bin/pwrctl",
        "/usr/sbin/ebtables",       # aarch64! pulls /lib64 + ld-linux-aarch64
    ],
    # Tier A4 - boot-rail storage/flash tools (mount-fs.sh, hndnvram.sh,
    # check-and-restore.sh) - non-busybox REAL binaries referenced by
    # /rom/etc/init.d/*.sh
    "seed:rail": [
        "/bin/ubiattach",
        "/bin/ubidetach",
        "/bin/ubiformat",
        "/bin/ubimkvol",
        "/bin/ubinfo",
        "/bin/ubirmvol",
        "/bin/mtd_debug",
        "/bin/mtdpart",
        "/bin/mmc",
        "/usr/sbin/mke2fs",
        "/usr/sbin/debug_monitor",  # coredump.sh rail
    ],
}

# Data trees grafted wholesale (read-only config + version-locked modules)
DATA_TREES = ["/rom", "/lib/modules"]
# Structural top-level files reproduced by the skeleton (listed for parity)
STRUCT_FILES = ["/.init_enable_core"]

# rc farm entries already stripped by rootfs-remove.list (keep in sync!)
REMOVED = {
    "/usr/sbin/infosvr", "/usr/sbin/awsiot", "/usr/sbin/mastiff",
    "/usr/bin/asd", "/usr/sbin/wsdd2", "/usr/sbin/networkmap",
    "/usr/networkmap", "/usr/sbin/uamsrv", "/usr/sbin/cfg_server",
    "/usr/sbin/wlc_nt", "/usr/sbin/lldpd", "/sbin/amas_lanctrl",
    "/sbin/amas_portstatus", "/sbin/amas_ssd_cd", "/sbin/conn_diag",
    "/usr/sbin/bsd", "/sbin/roamast", "/sbin/amas_bhctrl", "/sbin/amas_ssd",
    "/sbin/amas_status", "/sbin/amas_misc", "/sbin/amas_wlcconnect",
}


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True).stdout


def sha256(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def needed(p):
    out = run(["readelf", "-d", p])
    return re.findall(r"\(NEEDED\)\s+Shared library: \[([^\]]+)\]", out)


def interp(p):
    out = run(["readelf", "-l", p])
    m = re.search(r"interpreter: ([^\]]+)\]", out)
    return m.group(1) if m else None


def elf_class(p):
    """0 = not ELF, 1 = 32-bit, 2 = 64-bit."""
    try:
        with open(p, "rb") as f:
            h = f.read(5)
        return h[4] if h[:4] == b"\x7fELF" else 0
    except OSError:
        return 0


def is_elf(p):
    return elf_class(p) != 0


def resolve_lib(name, klass=None):
    """Find lib by soname in LIBDIRS (matching ELF class when given);
    return list of rootfs-relative paths (symlink chain first, real file
    last).  The blob is mixed-ABI: 32-bit ARM userspace + a few aarch64
    helpers (ebtables, Tuxera fs tools) using /lib64 - libc.so.6 exists in
    BOTH classes, so resolution must be class-aware."""
    for d in LIBDIRS:
        p = os.path.join(ROOT, d, name)
        if os.path.lexists(p):
            chain = []
            cur = p
            while os.path.islink(cur):
                chain.append("/" + os.path.relpath(cur, ROOT))
                tgt = os.readlink(cur)
                cur = tgt if tgt.startswith("/") else os.path.join(os.path.dirname(cur), tgt)
                cur = os.path.normpath(cur.replace("/", os.sep))
                if not cur.startswith(ROOT):  # absolute symlink inside rootfs
                    cur = ROOT + ("/" + tgt.lstrip("/") if tgt.startswith("/") else cur)
            if os.path.isfile(cur):
                if klass and elf_class(cur) != klass:
                    chain = []  # wrong ABI class - keep searching
                    continue
                chain.append("/" + os.path.relpath(cur, ROOT))
                return chain
    return []


def main():
    missing, closure, links, order = [], {}, {}, []
    seed_paths = {}

    for tier, paths in SEEDS.items():
        for p in paths:
            fp = ROOT + p
            if not os.path.isfile(fp):
                missing.append((tier, p))
                continue
            seed_paths[p] = tier

    # BFS over DT_NEEDED (class-aware: 32-bit ARM vs aarch64 helpers)
    queue = list(seed_paths)
    seen_names = set()  # (elf_class, soname)

    def add_lib(name, klass, via, optional=False):
        if (klass, name) in seen_names:
            return
        seen_names.add((klass, name))
        chain = resolve_lib(name, klass)
        if not chain:
            if not optional:
                missing.append(("closure", f"{name} (class {klass}, needed by {via})"))
            return
        for c in chain[:-1]:
            links.setdefault(c, os.readlink(ROOT + c))
        real = chain[-1]
        if real not in closure and real not in seed_paths:
            closure[real] = "lib"
            order.append(real)
            queue.append(real)

    while queue:
        rel = queue.pop(0)
        fp = ROOT + rel
        klass = elf_class(fp)
        if not klass:
            continue
        it = interp(fp)
        if it:
            add_lib(os.path.basename(it), klass, rel)
        for name in needed(fp):
            add_lib(name, klass, rel)
        # glibc loads NSS modules via dlopen at runtime - DT_NEEDED never
        # lists them.  Pull the matching-class nss/resolv set alongside libc.
        if os.path.basename(rel).startswith("libc.so"):
            for nss in ("libnss_files.so.2", "libnss_dns.so.2", "libresolv.so.2"):
                add_lib(nss, klass, rel + " (glibc NSS runtime)", optional=True)

    # rc multicall farm
    rc_links = {}
    for d in ["sbin", "bin", "usr/sbin", "usr/bin"]:
        dd = os.path.join(ROOT, d)
        if not os.path.isdir(dd):
            continue
        for f in sorted(os.listdir(dd)):
            p = os.path.join(dd, f)
            if os.path.islink(p):
                tgt = os.readlink(p)
                if os.path.basename(tgt) == "rc" and "busybox" not in tgt:
                    rel = "/" + d + "/" + f
                    if rel not in REMOVED:
                        rc_links[rel] = tgt
    rc_links["/sbin/init"] = "rc"  # explicit: PID1 wiring

    # dlopen candidates: .so strings in seeds+closure not already resolved
    resolved_sonames = {n for _, n in seen_names}
    dlopen_cand = set()
    so_re = re.compile(rb"[A-Za-z0-9_./-]*lib[A-Za-z0-9_.-]+\.so(?:\.[0-9.]+)?")
    for rel in list(seed_paths) + order:
        try:
            data = open(ROOT + rel, "rb").read()
        except OSError:
            continue
        for m in so_re.findall(data):
            name = os.path.basename(m.decode())
            if name not in resolved_sonames and resolve_lib(name):
                dlopen_cand.add(name)

    # ---------------------------------------------------------------- emit
    total_files = total_bytes = 0

    def emit(kind, rel, extra=""):
        nonlocal total_files, total_bytes
        fp = ROOT + rel
        sz = os.path.getsize(fp) if os.path.isfile(fp) else 0
        dig = sha256(fp) if os.path.isfile(fp) else "-"
        total_files += 1
        total_bytes += sz
        print(f"{kind:<12} {sz:>10} {dig} {rel}{extra}")

    print("# GT-BE98 Phase-3 ASUS graft manifest")
    print(f"# generated: {datetime.now(timezone.utc).isoformat()}")
    print(f"# generator: board/gt-be98/phase3/gen-graft-manifest.py {sys.argv[1]}")
    print("# blob: gt-be98-rootfs-0031 rootfs.img sha256 dfbf98b4d3a474887ad029e9e6347da081f013e615a607f4f083bb2f3ab28d2c")
    print("# format: <kind> <bytes> <sha256> <path-in-rootfs> [-> link target]")
    print()
    for tier in SEEDS:
        print(f"## [{tier}]")
        for p in SEEDS[tier]:
            if (tier, p) not in missing and p in seed_paths:
                emit(tier, p)
        print()
    print("## [closure] recursive DT_NEEDED of all seeds")
    for rel in sorted(order):
        emit("closure", rel)
    print()
    print("## [link] soname symlinks required for the closure")
    for rel in sorted(links):
        print(f"{'link':<12} {0:>10} {'-':64} {rel} -> {links[rel]}")
        total_files += 1
    print()
    print("## [link:rc] rc multicall farm (minus rootfs-remove.list entries)")
    for rel in sorted(rc_links):
        print(f"{'link:rc':<12} {0:>10} {'-':64} {rel} -> {rc_links[rel]}")
        total_files += 1
    print()
    print("## [kmod+data] trees grafted wholesale")
    for tree in DATA_TREES:
        n = b = 0
        for dirpath, _, files in os.walk(ROOT + tree):
            for f in files:
                fp = os.path.join(dirpath, f)
                if os.path.isfile(fp) and not os.path.islink(fp):
                    n += 1
                    b += os.path.getsize(fp)
        total_files += n
        total_bytes += b
        print(f"{'tree':<12} {b:>10} {'(whole tree, ' + str(n) + ' files)':64} {tree}")
    for p in STRUCT_FILES:
        if os.path.isfile(ROOT + p):
            emit("struct", p)
    print()
    print("## [dlopen?] .so strings present in graft binaries but not in any")
    print("## DT_NEEDED - possible dlopen targets; NOT auto-included, review:")
    for name in sorted(dlopen_cand):
        print(f"{'dlopen?':<12} {'?':>10} {'-':64} {name}")
    print()
    if missing:
        print("## [MISSING] seeds or libs not found (FIX BEFORE TRUSTING):")
        for tier, p in missing:
            print(f"MISSING {tier} {p}")
        print()
    print(f"# TOTAL: {total_files} files/links, {total_bytes} bytes "
          f"({total_bytes / (1 << 20):.1f} MiB) excluding dlopen candidates")


if __name__ == "__main__":
    main()

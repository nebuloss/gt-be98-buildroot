#!/usr/bin/env python3
"""Curate clean-applying in-tree CVE/stable fixes from the 4.19.295..325 incremental
stable patches and apply them IN PLACE to the kernel source.

Rules (per task mandate):
  - Target in-tree subsystems only: net/ (core, ipv4, ipv6, netfilter, bridge,
    sched, sctp, tipc, etc.), net/wireless, net/mac80211, net/bluetooth, crypto/,
    fs/cifs/, fs/ksmbd/, security/, lib/ (crypto helpers), sound? NO. keep tight.
  - SKIP any file Broadcom modified (contains BCM_KF marker in the pristine tree)
    -> these are where bcm patches the tree (skbuff/dev/tcp/ip/netfilter...).
  - SKIP Makefile (must NOT bump SUBLEVEL -> vermagic stays).
  - Apply per-file, in release order, ONLY if it applies with --fuzz=0 (no fuzz,
    no conflict). Log every applied vs skipped (file, release, reason).
  - Driver wireless (drivers/net/wireless/*) is mostly out-of-tree/closed on this
    box; SKIP to stay conservative (cfg80211/mac80211 live under net/).
"""
import os, re, subprocess, sys, glob

KSRC = "/home/guillaume/be98/gt-be98-firmware/vendor/asuswrt-merlin.ng/release/src-rt-5.04behnd.4916/kernel/linux-4.19"
PATCHDIR = "/home/guillaume/be98/job-tmp/kernel-fromsrc/cve/patches"
LOG = "/home/guillaume/be98/job-tmp/kernel-fromsrc/cve/curate.log"

# In-scope path prefixes (in-tree subsystems). Tight + conservative.
INSCOPE = (
    "net/core/", "net/ipv4/", "net/ipv6/", "net/netfilter/", "net/bridge/",
    "net/sched/", "net/sctp/", "net/tipc/", "net/packet/", "net/unix/",
    "net/socket.c", "net/wireless/", "net/mac80211/", "net/bluetooth/",
    "net/can/", "net/key/", "net/xfrm/", "net/dccp/", "net/rds/", "net/rxrpc/",
    "net/nfc/", "net/llc/", "net/9p/", "net/ax25/", "net/netrom/", "net/rose/",
    "net/atm/", "net/appletalk/", "net/x25/", "net/decnet/", "net/vmw_vsock/",
    "net/sunrpc/", "net/ceph/", "net/smc/", "net/qrtr/", "net/wireless/",
    "crypto/", "fs/cifs/", "fs/ksmbd/", "security/keys/", "lib/crypto/",
)

# Header subtrees from which we accept ONLY pure new-file additions (companion
# headers that a backport introduces, e.g. linux/indirect_call_wrapper.h). We do
# NOT edit pre-existing core headers (too broad / bcm-conflict risk) — only carry
# brand-new header files so in-scope .c consumers compile.
HEADER_NEWFILE_SCOPE = (
    "include/net/", "include/crypto/", "include/linux/", "include/uapi/linux/",
)

# Files excluded because their stable backport depends on cross-tree API changes
# (struct/func signature edits in out-of-scope core headers) that would require a
# much broader, non-conservative backport. Each is logged as a skipped CVE-area.
EXCLUDE = set([
    "net/bridge/br.c",          # switchdev br_fdb_offloaded_set/offloaded API change
    "net/core/net_namespace.c", # pernet_operations.pre_exit field backport
    "net/ipv4/tcp_rate.c",      # tcp_skb_cb/rate API backport
    "net/ipv4/tcp_recovery.c",  # tcp rack API backport
    "net/ipv6/route.c",         # fib6/rt6 API backport
    "fs/cifs/cifsfs.c",         # needs lookup_positive_unlocked() (dcache.h backport)
    "net/bridge/br_switchdev.c",# switchdev_notifier_fdb_info.offloaded / BR_FDB_* API
    "net/netfilter/nf_tables_api.c",  # nft_setelem_data_deactivate / NFT_TABLE_F_MASK
    "net/netfilter/nft_dynset.c",     # nf_msecs_to_jiffies64 helpers (nf_tables.h)
    "net/netfilter/nft_lookup.c",     # nft_set_datatype() (nf_tables.h)
    "net/unix/af_unix.c",       # unix_sk refcount/scm rework (af_unix.h, multi-file)
    "net/unix/garbage.c",       # part of unix scm refcount rework
    "net/unix/scm.c",           # part of unix scm refcount rework
    "net/xfrm/xfrm_policy.c",   # netns_xfrm.idx_generator field backport
])

def is_inscope(path):
    if path in EXCLUDE:
        return False
    return any(path == p or path.startswith(p) for p in INSCOPE)

def bcm_modified(path):
    full = os.path.join(KSRC, path)
    if not os.path.exists(full):
        return False
    try:
        with open(full, "rb") as f:
            return b"BCM_KF" in f.read()
    except Exception:
        return True  # be conservative

def split_per_file(patch_text):
    """Yield (path, single-file-diff-text) from a git-format unified diff."""
    parts = re.split(r"(?m)^(?=diff --git )", patch_text)
    for p in parts:
        if not p.startswith("diff --git "):
            continue
        m = re.match(r"diff --git a/(\S+) b/(\S+)", p)
        if not m:
            continue
        yield m.group(2), p

def try_apply(file_diff, dry):
    args = ["patch", "-p1", "--no-backup-if-mismatch", "--fuzz=0", "-s"]
    if dry:
        args.append("--dry-run")
    r = subprocess.run(args, input=file_diff, text=True, cwd=KSRC,
                       capture_output=True)
    return r.returncode == 0, (r.stdout + r.stderr).strip()

def main():
    applied = []   # (release, path)
    skipped = []   # (release, path, reason)
    logf = open(LOG, "w")
    def log(s):
        print(s); logf.write(s + "\n")

    for n in range(295, 326):
        pf = os.path.join(PATCHDIR, "p-%d" % n)
        if not os.path.exists(pf):
            continue
        text = open(pf, encoding="utf-8", errors="replace").read()
        for path, fdiff in split_per_file(text):
            if path == "Makefile":
                skipped.append((n, path, "makefile-sublevel-bump")); continue
            if path in EXCLUDE:
                skipped.append((n, path, "cross-tree-API-dep (out-of-scope core header change)")); continue
            in_main = is_inscope(path)
            in_hdr = any(path.startswith(p) for p in HEADER_NEWFILE_SCOPE)
            if not in_main and not in_hdr:
                continue  # silently out of scope (not logged to keep noise down)
            if in_hdr and not in_main:
                # Only carry brand-new header files (target must not already exist).
                if os.path.exists(os.path.join(KSRC, path)):
                    continue  # editing an existing core header -> out of scope, skip silently
            if bcm_modified(path):
                skipped.append((n, path, "bcm-modified-file")); continue
            ok, msg = try_apply(fdiff, dry=True)
            if not ok:
                skipped.append((n, path, "conflict/fuzz: " + msg.replace("\n", " ")[:120]))
                continue
            ok2, msg2 = try_apply(fdiff, dry=False)
            if ok2:
                applied.append((n, path))
            else:
                skipped.append((n, path, "apply-failed-after-dryok: " + msg2[:100]))

    log("=== APPLIED (%d file-diffs) ===" % len(applied))
    for n, p in applied:
        log("  +4.19.%d  %s" % (n, p))
    log("=== SKIPPED in-scope (%d) ===" % len([s for s in skipped if s[2] != 'makefile-sublevel-bump']))
    for n, p, r in skipped:
        if r == "makefile-sublevel-bump":
            continue
        log("  -4.19.%d  %s   [%s]" % (n, p, r))

    # Distinct files touched
    files = sorted(set(p for _, p in applied))
    log("=== DISTINCT FILES PATCHED (%d) ===" % len(files))
    for f in files:
        log("  " + f)
    logf.close()

if __name__ == "__main__":
    main()

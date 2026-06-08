# GT-BE98 from-source CVE-hardened 4.19.294 kernel — build notes

**Goal**: produce a from-source, vermagic-preserved, CVE-hardened 4.19.294 kernel
packaged into a trial-ready `.pkgtb`. Version is pinned; source is rebuilt.
NO flash, NO merge/push. 2026-06-08.

## TL;DR deliverables

| Artifact | Status | sha256 |
|---|---|---|
| `artifacts-br/GT-BE98_kernel-fromsrc-base.pkgtb` | ✅ BUILT + VALIDATED | `eb435bc8ca8bfa54cdceac1dd230e77ee5ebdd2a023af41f864a070a61a5f0fb` |
| `artifacts-br/GT-BE98_kernel-cve-hardened.pkgtb` | ⛔ BLOCKED at vmlinux relink (SDK glue) — patches applied + compile-clean | — |

- **Baseline `.pkgtb`** (47 555 268 B): from-source kernel, **byte-identical to the
  device kernel**, repacked into the v31 bootfs.itb (only kernel swapped) + v31
  rootfs squashfs. Well-formed FIT (verified `dumpimage -l`). This is the
  foundation artifact and proves the entire build+repack pipeline.
- **CVE-hardened**: 261 clean in-tree stable patches (4.19.295→325) applied to
  net/crypto/fs/security/lib; **all patched subsystems compile with 0 errors**;
  vermagic + closed-.ko ABI provably unchanged. Only the final full-vmlinux relink
  is blocked (platform-driver SDK glue, see Blocker).

## Build environment (proven)

- Source: `…/src-rt-5.04behnd.4916/kernel/linux-4.19` (Makefile 4.19.294, EXTRAVERSION=,
  `# CONFIG_MODVERSIONS is not set`, no MODULE_SIG, SMP=y PREEMPT=y MODULE_UNLOAD=y).
- Toolchain (aarch64): `crosstools-aarch64-gcc-10.3-…-glibc-2.32-binutils-2.36.1`,
  prefix `aarch64-buildroot-linux-gnu-` (under `…/usr/bin`).
- Kernel make env (the missing-glue lessons that made it build):
  `ARCH=arm64 CROSS_COMPILE=… LINUX_VER_STR=4.19.294 BCM_KF=y BUILD_NAME=gt-be98
   BRCM_CHIP=6813 BCM_CHIP=6813 BRCM_BOARD=bcm963xx PROFILE_DIR=…/targets/96813GW
   BUILD_DIR=<SDK> SHARED_DIR=<SDK>/shared KERNEL_DIR=<KSRC> BRCMDRIVERS_DIR=<SDK>/bcmdrivers`
  and **KCFLAGS must include `-I<bcmkernel>/include/uapi`** (resolves
  `linux/netfilter/xt_FSMARK.h`) plus the bcmdrivers/shared bcm963xx includes and
  `-DBCA_HNDROUTER -DBCA_CPEROUTER -DGTBE98`. Without the SDK dir-vars the
  `Makefile.brcm_pre` LINUXINCLUDE injection (`-Inet/bridge`, bcm uapi) is empty
  and bcmkernel files (blog.c/br_private.h) fail to find headers.

## Step 1 — baseline from-source build: VALIDATED

- Rebuilt `arch/arm64/boot/Image` = **byte-identical** to the kernel inside v31's
  `bcm96813GW_uboot_linux.itb` (decompress that itb's `kernel` lzo node → matches Image).
- `bare lzop < Image` (input mtime normalized to `0x6a22ddf8`) reproduces v31's
  kernel `.lzo` node **byte-for-byte** (6 946 472 B). The merlin recipe is exactly
  `lzop < vmlinux.bin > vmlinux.bin.lzo` (bootloaders/Makefile:819, default level).
- vermagic of a freshly-built in-tree `.ko`: `4.19.294 SMP preempt mod_unload aarch64` ✅
- **closed-.ko symbol invariant**: the 37 closed `.ko` import **1541** distinct
  symbols; resolved against rebuilt `Module.symvers` (9867 exports) + inter-.ko
  defs → **0 unresolved**. ABI intact.

## Step 2 — baseline repack: VALIDATED

`.pkgtb = [outer FIT-DTB] + [bootfs.itb] + [rootfs.squashfs]` (data-offset 0 / itb-size).
The inner `bootfs.itb` is itself a FIT (ATF + u-boot + kernel(lzo) + ~40 DTBs) using
external `data-position`. We **surgically swap ONLY the kernel** inside the v31
DEVICE itb (`swap-kernel-itb.py`): extract all 62 image blobs by position, replace
the kernel blob, regenerate via the SDK `mkimage -E -p <pad=fit_header_tool 1280>`.
Verified: all **62 data blobs byte-identical to device**, kernel hash matches device,
only the FIT timestamp + DTS property-source-order differ. Outer repack via
`repack-pkgtb.py` (mirrors v31). Final `dumpimage -l`: bootfs 13 328 136 B,
nand_squashfs 34 226 176 B (rootfs sha `fed6cf3d…` == v31). Well-formed. ✅

## Step 3 — CVE backports: applied + compile-clean (vermagic/ABI preserved)

Mined the incremental stable patches **4.19.295 → 4.19.325** (all 31 fetched from
cdn.kernel.org). Per-file, in release order, applied ONLY hunks that apply with
`patch --fuzz=0` (no fuzz/conflict), scoped to in-tree subsystems, skipping any
Broadcom-modified file (`BCM_KF` marker) and the Makefile (no SUBLEVEL bump).
Harness: `curate-cve.py`; full audit: `curate.log`.

- **APPLIED**: 261 file-diffs across 189 distinct files (61 compiled in this config).
  By subsystem (compiled .c): netfilter 24, sched 13, bluetooth 12, mac80211 9,
  ipv6 9, ipv4 9, cifs 5, crypto 5, sctp 4, keys 2, wireless/cfg80211 2, bridge 2,
  packet/unix(scm-safe subset)/tipc/smc/llc/rds/9p/ceph/dccp/rxrpc/nfc/vsock …
  Companion new-file headers carried in: `linux/indirect_call_wrapper.h` (.297),
  `linux/units.h` (.307).
- **SKIPPED — Broadcom-modified files (84 diffs, 36 distinct)**: the bcm tree patches
  these so stable hunks conflict — skipping is mandatory to keep the bcm datapath
  intact. Notable: `net/core/{skbuff,dev,sock,rtnetlink}.c`,
  `net/ipv4/{tcp,tcp_input,tcp_output,route,esp4,ip_output,ip_gre,af_inet,…}.c`,
  `net/ipv6/{addrconf,ip6_output,esp6,tcp_ipv6,syncookies,…}.c`,
  `net/bridge/{br_fdb,br_forward,br_input,br_private.h}`, `net/mac80211/tx.c`,
  `net/wireless/{nl80211,util}.c`, `net/xfrm/xfrm_user.c`,
  `net/netfilter/nf_conntrack_netlink.c`, `crypto/{aead,algapi,algif_aead}.c`.
- **SKIPPED — cross-tree-API deps (37 diffs)**: backport needs a struct/func/macro
  change in an OUT-OF-SCOPE core header (would force a non-conservative broad
  backport). Excluded files (each logged): `net/ipv4/{tcp_rate,tcp_recovery}.c`
  (tcp rack/rate API), `net/ipv6/route.c` (fib6/rt6 API), `net/core/net_namespace.c`
  (`pernet_operations.pre_exit`), `net/bridge/br.c` + `net/bridge/br_switchdev.c`
  (`switchdev_notifier_fdb_info.offloaded`/`BR_FDB_*`), `fs/cifs/cifsfs.c`
  (`lookup_positive_unlocked`), `net/netfilter/{nf_tables_api,nft_dynset,nft_lookup}.c`
  (nf_tables.h helper/macro backports), `net/unix/{af_unix,garbage,scm}.c` (unix_sk
  refcount/scm rework), `net/xfrm/xfrm_policy.c` (`netns_xfrm.idx_generator`).
- **SKIPPED — already-present / reverse (2)**: `net/wireless/certs/wens.hex` (file
  already exists), `net/sched/sch_dsmark.c` (reverse/already-applied).

**vermagic/ABI preservation proof**: no patch touched the SMP/PREEMPT/MODULE_UNLOAD/
MODVERSIONS/MODULE_SIG config or the Makefile SUBLEVEL → vermagic stays
`4.19.294 SMP preempt mod_unload aarch64`. The only EXPORT_SYMBOL delta among
patched files is `crypto/af_alg.c` (24→18, a stable refactor of algif-internal
helpers); its symbols have **ZERO intersection** with the 1541 closed-.ko imports —
the closed-driver ABI is unaffected.

**Compile proof**: `make -k net/ crypto/ fs/ security/ lib/` on the patched tree →
**0 compile errors** (after the exclusions above). The CVE-patched
net/crypto/fs/security/lib `built-in.a` archives build cleanly.

## Step 4 — hardened repack: BLOCKED at the vmlinux relink (SDK glue)

A full `make Image` relink re-descends the **bcmdrivers/bcmkernel obj-y PLATFORM
drivers** built INTO vmlinux (`board`, `plat-bcm`, `phy`, timer, dgasp, …). Their
`.o`/sub-`built-in.a` objects were cleaned from this checkout, and the top-level
`bcmdrivers/built-in.a` is a *thin* archive pointing at the now-missing `.o`s.
Regenerating them requires the **SDK top-level orchestration** that the bare kernel
make does not reproduce: per-subdir `EXTRA_CFLAGS` (e.g. `-I…/include/bcm963xx/pmc`),
SDK-generated headers (`clk_rst.h`, `pmc_core_api.h`), and a `mkdir /etc/fw` install
step (root). This is the documented "SDK top-level make glue" wall — and it is
**independent of the CVE work**: even a clean baseline relink would hit it because
the platform `.o`s are absent. The CVE-patched kernel built-ins themselves compile
fine; only the platform relink is glue-bound.

To finish Step 4, drive the kernel via the SDK target `make -C build -f Bcmkernel.mk
Image` after `headers_install`/`rdp_link` (which create the symlinks + generated
headers), OR restore the original platform `.o`/`built-in.a` set, then re-run
`build-kernel-pkgtb.sh hardened` (the lzo→swap→repack path is proven and reused
verbatim from the baseline, which IS byte-validated).

## Trial command + GATE (operator, after Step 4 completes)

```
# arms the spare slot only; committed slot is the untouched recovery target
GT_BE98_PORT=2222 board/gt-be98/flash/open-flash.sh \
    artifacts-br/GT-BE98_kernel-cve-hardened.pkgtb     # (or …-fromsrc-base.pkgtb)
# then reboot; the trial dead-man reverts to GOOD on failure
```

**GATE — operator MUST verify after boot (auto-revert will NOT catch a .ko-load
failure: that leaves mgmt plane up but wifi/datapath down):**
1. `cat /sys/module/wl/version` / `modinfo` — loaded modules vermagic ==
   `4.19.294 SMP preempt mod_unload aarch64`.
2. `lsmod` shows all 35+ closed `.ko` loaded (esp. wl, dhd, rdpa, pktflow, hnd,
   bcm_enet) — a vermagic/symbol mismatch = silent module-load failure.
3. WiFi associates on all 3 radios; a client gets an IP.
4. Datapath/internet works (HW-offloaded forwarding via the rebuilt kernel).
Only after all four pass should the operator commit the trial slot.

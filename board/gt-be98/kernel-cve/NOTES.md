# GT-BE98 from-source CVE-hardened 4.19.294 kernel — build notes

**Goal**: produce a from-source, vermagic-preserved, CVE-hardened 4.19.294 kernel
packaged into a trial-ready `.pkgtb`. Version is pinned; source is rebuilt.
NO flash, NO merge/push. 2026-06-08.

## TL;DR deliverables

| Artifact | Status | sha256 |
|---|---|---|
| `artifacts-br/GT-BE98_kernel-fromsrc-base.pkgtb` | ✅ BUILT + VALIDATED | `eb435bc8ca8bfa54cdceac1dd230e77ee5ebdd2a023af41f864a070a61a5f0fb` |
| `artifacts-br/GT-BE98_kernel-cve-hardened.pkgtb` | ✅ BUILT + VALIDATED (relink SOLVED 2026-06-08) | `174eb96354e53431a5f2d238456cae0ca73eaf95245e763853131f5c8c745d96` |

**HARDENED pkgtb** (47 541 332 B): full-vmlinux relink with the 261-diff/189-file CVE
backports (61 compiled in this config), repacked into the v31 bootfs.itb (ONLY the
kernel swapped — 61/61 non-kernel blobs byte-identical to device) + the v31 rootfs
squashfs (sha `fed6cf3d…`, unchanged). Hardened Image: 11 673 608 B, sha
`7990db5c…`. vermagic `4.19.294 SMP preempt mod_unload aarch64` UNCHANGED on both
vmlinux and the rebuilt cfg80211.ko. Closed-.ko ABI: 1541 imports → **0 unresolved**
(1449 covered by closed-ko ksymtab + vmlinux Module.symvers; the 34 cfg80211_*/
ieee80211_*/wiphy_* imports resolve against the rebuilt in-tree cfg80211.ko, all 34
exports preserved).

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

## Step 4 — hardened relink + repack: ✅ SOLVED (2026-06-08)

The relink wall was NOT "SDK top-level make required". It decomposed into THREE
concrete, fixable items, all driven from a bare `make Image` once the env is right:

1. **2 platform `.o`s were physically deleted** from the bcmdrivers thin archive
   (`opensource/char/board/bcm963xx/impl1/board_proc.o` and
   `opensource/char/plat-bcm/impl1/bcm_arm64_setup.o`). Regenerated by replaying
   their kbuild `.<name>.o.cmd` (self-contained, original flags). All other ~916
   platform `.o`s were intact.
2. **Per-subdir EXTRA_CFLAGS referenced un-exported SDK make-vars** → the pmc
   headers (`pmc_core_api.h`, `pmc_ssb_access.h`, `clk_rst.h`) are NOT generated;
   they EXIST at `bcmdrivers/opensource/include/bcm963xx/pmc/` but weren't on the
   include path. Fix = export the make.common vars verbatim (defs at make.common
   :1221-1240):
   `INC_BRCMDRIVER_PUB_PATH=$SDK/bcmdrivers/opensource/include`,
   `INC_BRCMDRIVER_PRIV_PATH=$SDK/bcmdrivers/broadcom/include`,
   `INC_BRCMSHARED_PUB_PATH=$SDK/shared/opensource/include`,
   `INC_BRCMSHARED_PRIV_PATH=$SDK/shared/broadcom/include`,
   plus the board macros `BRCM_BOARD_ID=GT-BE98 BRCM_NUM_MAC_ADDRESSES=11
   BRCM_BASE_MAC_ADDRESS=20:CF:30:00:00:00` (read from the original board_proc .cmd).
3. **`/etc/fw` write** (`phy/Makefile:683`, `INSTALL_PATH=$(INSTALL_DIR)/etc/fw`,
   INSTALL_DIR empty → host root). It is a target-rootfs PHY-firmware copy,
   IRRELEVANT to vmlinux/Image. Fix = `export INSTALL_DIR=<writable staging>`.

★ALSO CRITICAL — config hygiene★: do **NOT** `make olddefconfig` on `config_gt-be98`
(a hand-merged config with duplicate keys; olddefconfig drops INET/NETFILTER/CBQ/…
and mangles dozens of symbols → wrong build). Use `cp config_gt-be98 .config &&
make syncconfig` (last-wins honored, only genuinely-new symbols defaulted). With
that, the **baseline relink is byte-identical to the device kernel except the 40-byte
build banner** (`#N` build-count + date; vermagic `SMP PREEMPT` identical) — proving
the relink path is exact.

CVE delta note: 4.19.308 (p-308) **removes sch_cbq + sch_dsmark** (Kconfig + .c) —
the upstream qdisc-removal hardening. That accounts for the hardened Image being
67 584 B smaller than baseline; it is an intended CVE delta, not a regression.

★MODULE-RESIDENT FIXES CAVEAT★: the hardened **vmlinux** carries all built-in CVE
fixes (net core, ipv4/6, netfilter, sctp, crypto, fs, security, lib — 61 compiled
files). But in-tree **modules** ship in the ROOTFS. `CONFIG_MAC80211` is OFF (wl
provides its MAC), so the only CVE-relevant in-tree module that ships is
**cfg80211.ko** (fixes to scan.c/sme.c). This pkgtb reuses the UNCHANGED v31
squashfs → its cfg80211.ko is the pre-CVE one. The hardened cfg80211.ko is rebuilt
(vermagic preserved, 34/34 exports intact) and staged at
`job-tmp/kernel-fromsrc/hardened-modules/cfg80211.ko`; to fully land the wireless
CVE fixes, drop it into the rootfs (it loads fine against either vmlinux — vermagic
+ ABI unchanged). The closed wl/dhd/rdpa stack is unaffected.

Reproduce: `cp config_gt-be98 .config && make syncconfig`, then `make Image` with
the env above (see build-kernel-pkgtb.sh, which now exports all of it), then the
proven lzo→swap-kernel-itb.py→repack-pkgtb.py path.

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

## Step 5 — v33 unified image: hardened kernel + v32 rootfs (PURE REPACK, 2026-06-09)

**Why**: the hardened pkgtb (Step 4) carries the v31 rootfs, which predates the
OpenSSL-3 hostapd promotion (v32). Trialing the hardened kernel as-is would
regress hostapd back to the pre-openssl3 build. v33 = hardened **kernel** FIT +
v32 **rootfs**, so the CVE-hardened kernel can be trialed with the v32 userspace
intact. No rebuild — pure repack of two validated `.pkgtb`s.

| Artifact | sha256 |
|---|---|
| `artifacts-br/GT-BE98_openrc-init-v33_nand_squashfs.pkgtb` | `566dc9680ff7ee241ed0a9045efc9dc28df8da173a146569b291fe6b1c4ca7f1` (48 839 764 B) |

**Inputs** (both pre-validated):
- HARDENED `GT-BE98_kernel-cve-hardened.pkgtb` (sha `174eb963`) → take **image 0**
  bootfs.itb (sha `d73dfafa…`, the 61-CVE hardened vmlinux). Discard its image 1
  (v31 rootfs `fed6cf3d…`).
- V32 `GT-BE98_openrc-init-v32_nand_squashfs.pkgtb` (sha `90c64182`) → take
  **image 1** nand_squashfs (sha `0de17e56…`, rc-free + self-heal +
  hostapd-openssl3). Discard its image 0 (kernel).

**Method**: `repack-v33-unified.sh` — `dumpimage -T flat_dt -p 0` / `-p 1` to
split (identical to `open-flash.sh`), then `repack-pkgtb.py` **verbatim** to
assemble the same external-data FIT (bootfs @offset 0 + nand_squashfs +
conf_6813_a0+_nand_squashfs + per-segment sha256).

**Verified**:
- `dumpimage -l` → well-formed FIT, image 0 = `d73dfafa…`, image 1 = `0de17e56…`.
- open-flash split (`-p 0` / `-p 1`) recovers both segments **byte-identical**
  (`cmp` clean) to the hardened bootfs.itb and the v32 squashfs.
- Provenance sanity: v33 bootfs **differs** from v32's kernel (kernel came from
  hardened, not v32); v33 rootfs **differs** from the v31 rootfs inside the
  hardened pkgtb (rootfs is v32, not v31). ⇒ exactly hardened-kernel + v32-rootfs.

**CVE caveat (carries from Step 4)**: the 61 built-in CVE fixes are in the
hardened **vmlinux** that v33 ships. The in-tree **cfg80211.ko** in the v32
rootfs is still the pre-CVE one — to land the wireless-CVE cfg80211 fix, drop the
rebuilt hardened `cfg80211.ko` into the rootfs before squashing (vermagic + 34/34
exports unchanged, loads against either vmlinux).

**Trial**: same GATE as Step 4; flash `GT-BE98_openrc-init-v33_nand_squashfs.pkgtb`
to the spare slot. NO FLASH done here — repack only.

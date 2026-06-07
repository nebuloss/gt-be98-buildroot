# OpenRC-PID1 open-init rootfs — design, build state, blocker map

Build-only exploration (offline, no device, no flash). Goal: replace the ASUS
`rc` PID1 on the br-0050 baseline with **OpenRC (`openrc-init`)** + the open
userspace, keeping the pinned Broadcom graft. Per
`[[prefer-openrc-over-custom-pid1]]` — a widely-tested init, NOT a hand-rolled
PID1.

## 1. ASUS rc PID1 early-init map (what OpenRC must replicate)

`/sbin/init -> rc`; `main()` dispatches basename `init`/`preinit` -> `init_main()`
(rc.c:3010, init.c:26117). Sequence on GT-BE98 (`RTCONFIG_HND_ROUTER_BE_4916`):

| Step | Source | What | graft? |
|------|--------|------|--------|
| 1 | init.c:26151 | `mount -t ubifs ubi:data /data; insmod bcm_knvram` | **GRAFT** (closed .ko) |
| 2 | init.c:25000 (sysinit) | `bcm_boot_launcher start` -> runs `/rom/etc/rc3.d/S25..S50` | **GRAFT** (self-contained) |
| 2a | S25mount-fs | `mount -a`, `/proc/bootstate/{reset_reason,boot_failed_count}`, `mdev -s`, `make_static_devnodes.sh`, mount `/data` | mostly generic; `/proc/bootstate` kernel-specific |
| 2b | S40hndnvram | `nvram kernelset /data/.kernel_nvram.setting` (populate kernel nvram tree) + `restore_mfg` | **GRAFT** (nvram CLI + bcm_knvram) |
| 2c | S41wluboot2knvram | wl uboot params -> knvram | **GRAFT** |
| 2d | S45bcm-base-drivers | **closed HW-datapath .ko load ORDER**: bcmlibs, bcm_knvram, bdmf, rdpa_gpl, bcm_mpm/bpm, bcmvlan, rdpa(_prv/_usr/_mw), bcm_bp3drv, bcm_ingqos, pktflow, cmdlist, gdx, sw_gso, bcm_enet, pcap, rdpa_cmd, pktrunner, bcmmcast, bcm_pcie_hcd, wfd, hs_uart_drv, bcmflex, bcmspu, bcm_thermal + GPIO reset pokes + rdpa_init.sh | **GRAFT** (closed .ko) |
| 2e | S45bcm-wlan-drivers | `wl.ko`/`dhd.ko` + radio firmware (per nvram `wl_unitlist`) | **GRAFT** |
| 3 | init.c:24745 (start_hw_wdt) | `wdtctl -d -t <watchdog_new/1000> start` | **GRAFT** (`wdtctl` closed *ctl) |
| 4 | sysinit body | mounts `/proc /sys /dev /tmp /var /dev/pts /dev/shm`, dev nodes, sysctl (`min_free_kbytes`, `panic=3`, overcommit), **/etc symlink farm**, `mtab`, `resolv.conf`, `ldconfig`, console getty | **GENERIC** (OpenRC stock) |
| 5 | init.c:26196+ | `start_jffs2` (mount /jffs), `restore_cert`, `setup_passwd`, `run_custom_script init-start` | GENERIC |
| 6 | init.c:26581 (START) | `config_switch()` / `config_extwan()` (HW switch) | **GRAFT, but standalone applets** (rc.c:4388/4394 — run in-process, no PID1 signal) |
| 7 | init.c:26594 | `start_lan()` — bridges br0 + eth ports + LAN IP + enet/runner attach | **GRAFT-adjacent, NOT a standalone applet** -> see Blocker B |
| 8 | init.c:26597 | `start_wl()` + `lanaccess_wl()` — radio up | GRAFT; replaced by open EnsureRadio |
| 9 | init.c:26613 | `rtpolicy auto ALL` (Runner policy) | **GRAFT** |
| 10 | init.c:26626 | `start_services()` — eapd/wlceventd/mcpd/hostapd/dnsmasq/webui/... | mixed (open + pinned glue) |
| 11 | main loop | sigwait(initsigs); respawn/watchdog; **`sync_boot_state()`** (init.c:27102, bootstate self-commit); `waitpid` reaper | reaper GENERIC; self-commit -> dead-man (Blocker C) |

**Headline:** the entire graft early-init (steps 1,2,3,9) is **self-contained in
`bcm_boot_launcher` + `/rom/etc/rc3.d` + a handful of closed CLIs**. OpenRC does
NOT reimplement any of it — it INVOKES it in order. ~90% of the graft early-init
is one service (`bcm-platform` -> `bcm_boot_launcher start`).

## 2. OpenRC init sequence (this directory)

PID1 = `openrc-init` (OpenRC's own bundled minimal init; `BR2_INIT_OPENRC`).
Runlevels: `sysinit -> boot -> default`.

```
sysinit:  deadman-early   <- FIRST: mount /data, fork /sbin/trial-deadman ([[early-deadman]])
          etc-farm        <- rebuild the runtime /etc tmpfs farm (see Blocker A)
          devfs procfs sysfs dmesg   <- OpenRC stock (from the package)
boot:     bcm-knvram      <- mount ubi:data /data + insmod bcm_knvram      [graft]
          bcm-platform    <- bcm_boot_launcher start (rc3.d S25-S50)        [graft]
          hw-wdt          <- wdtctl arm (watchdog; /dev/watchdog conflict)  [graft]
          net-switch      <- rc config_switch + config_extwan + br0 bring-up [graft+BLOCKER B]
default:  wifi-radio      <- eapd/wlceventd/mcpd glue; radios via webui      [graft glue]
          webui           <- webui-go controller (EnsureRadio + hostapd + :80)
```

Service scripts: `init.d/*` (openrc-run format, with `depend()` ordering).

## 3. BUILD state  — SQUASHFS PRODUCED [V] (2026-06-07, online)

Cross-build of OpenRC (the prior build blocker) is CLEARED. Isolated build:
`configs/gt-be98_openrc-init_defconfig` (copy of `gt-be98_full_defconfig` with
`BR2_INIT_OPENRC=y` + `BR2_PACKAGE_OPENRC=y`; production config UNTOUCHED), built
in `output-openrc-init/` (`make ... openrc` only — no full firmware rebuild).

- **OpenRC version:** 0.56 (`package/openrc`, github OpenRC/openrc, glibc
  arm-buildroot-linux-gnueabi gcc-10.3). Deps pulled: host-python3/meson/ninja,
  libcap, ncurses, libxcrypt.
- **sysconfdir=/rom/etc [V] (blocker A resolved-in-build):** OpenRC built with
  `--sysconfdir=/rom/etc` via `OPENRC_CONF_OPTS += --sysconfdir=/rom/etc`
  (`0001-openrc-build-sysconfdir-rom-etc.patch`, appended last so it wins over
  the meson default `/etc`). Verified in the binary strings: `librc.so.1` carries
  `/rom/etc/runlevels`, `/rom/etc/init.d`, `/rom/etc/conf.d/rc`.
- **REAL 0.56 layout** (the speculative paths in the old assemble.sh were wrong):
  bins in `/sbin` (openrc-init, openrc [== the old `rc`], openrc-run,
  openrc-shutdown, rc-update, rc-service) + `/bin/rc-status`; libs in
  `/usr/lib/lib{rc,einfo}.so*`; helpers in `/usr/libexec/rc/**`; stock config in
  `/rom/etc/{rc.conf,conf.d,init.d,local.d,sysctl.d}`.
- **`openrc-assemble.sh <baseline> <out> [stage]`** unsquashes the br-0050
  baseline, overlays the full OpenRC footprint from `output-openrc-init/target`,
  adds the stock VFS service scripts + the 8 custom services into
  `/rom/etc/init.d`, rebuilds `/rom/etc/runlevels/{sysinit,boot,default}`, swaps
  `/sbin/init -> /sbin/openrc-init`, and re-squashes merlin-exact
  (`-noappend -all-root -comp xz -b 131072`).
- **BUILT — v1 SUPERSEDED (wrong base) [defect]:** the first open-init rootfs
  (`GT-BE98_openrc-init_nand_squashfs.pkgtb`, rootfs `64,245,760 B`, sha
  `77c041ec…`) was assembled on the RAW base `artifacts-0035/rootfs.img` (64 MB)
  instead of the FULL deployed br-0050 (`69,894,144 B`). It was MISSING 28 br-0050
  entries — CRITICALLY the entire `/usr/br` tree (`dropbearmulti` = the `:2223`
  RESCUE SSH, busybox, openssl, ssh/scp/sftp, ssl certs), `/sbin/trial-deadman`
  (the DEAD-MAN), and `/rom/etc/init.d/{trial-deadman.sh,br-dropbear.sh,
  boot-breadcrumb.sh}` — i.e. the trial SAFETY NET. DO NOT FLASH v1.
- **REBUILT [V] (2026-06-07, v2, CORRECT FULL base):** re-ran `openrc-assemble.sh`
  against the FULL br-0050 rootfs (Image 1 of `GT-BE98_blob0035_nand_squashfs.pkgtb`,
  `69,894,144 B`, sha `a5179579…`). New squashfs `70,107,136 B` (66.86 MiB; base
  `69,894,144` + `212,992` OpenRC), under the slot-2 ceiling `71,106,560`
  (`999,424 B` headroom). Exceeds slot-1's ~67.8 MB so it trials on slot-2 — fits.
  All 8 custom + 4 stock sysinit symlinks resolve. **Image-diff vs FULL br-0050:
  ONLY 173 OpenRC-owned adds + the single `/sbin/init: rc -> /sbin/openrc-init`
  swap; ZERO br-0050 removals — all 28 previously-missing entries PRESENT.** Graft
  byte-identical (`bcm_boot_launcher`, `wl.ko`, `dhd.ko`, `bcm_knvram.ko`, `nvram`,
  `bcm-base-drivers.sh`, `/rom/etc/rc3.d`). **Safety net CONFIRMED present:
  `/usr/br/sbin/dropbearmulti`, `/sbin/trial-deadman` (4413 B, sha-match base),
  `/rom/etc/init.d/{br-dropbear.sh,boot-breadcrumb.sh,trial-deadman.sh}`.**
  Dead-man fork verified: `deadman-early` forks `/sbin/trial-deadman`, which EXISTS
  in this rootfs (no fix needed). pkgtb (br-0050 boot-chain FIT, bootfs Image 0
  byte-identical, sha `81f38fe0…`):
  `~/be98/artifacts-br/GT-BE98_openrc-init-v2_nand_squashfs.pkgtb`
  (`83,436,232 B`, sha `697e5477…`; rootfs Image 1 sha `301f3a63…`).
  **This is the SAFE-to-flash open-init image.**
- **NOT VERIFIED (bench-only):** that openrc-init-as-PID1 actually boots the
  closed bcm stack (blocker F), glibc ABI of the merlin libc against these
  binaries at runtime, and runlevel execution order live. Build-buildable only.

## 4. Blocker map (honest)

- **A. No persistent `/etc` [V-src, structural].** The merlin rootfs has
  `/etc -> tmp/etc` (runtime tmpfs); persistent config is in read-only `/rom/etc`.
  ASUS rc hand-builds `/etc` in sysinit. OpenRC's `/etc/{init.d,runlevels}` model
  assumes a persistent `/etc` that does NOT exist when PID1 starts. **Resolution
  (implemented here):** install OpenRC config in `/rom/etc`, build OpenRC with
  `--sysconfdir=/rom/etc`, and run `etc-farm` as the 2nd sysinit service to
  rebuild the writable `/etc` farm. **The `--sysconfdir=/rom/etc` build flag is
  now APPLIED + confirmed compiled into `librc.so.1` [V] (resolved-in-build).**
  The `etc-farm` runtime rebuild of the writable `/etc` remains bench-unverified.
- **B. `start_lan` is not a standalone applet [V-src].** `config_switch`/
  `config_extwan` ARE reachable rc applets (run in-process), but bridge/eth
  bring-up (`start_lan`) is rc-internal to the START state. A faithful open
  `start_lan` (brctl/ip per nvram `lanX_ifnames` + bcm enet/runner netdev attach
  order) is OWED. `net-switch` ships a first-cut br0 bring-up that is NOT a
  verified equivalent. Recommended owner: webui-go (already does port/bridge mgmt).
- **C. Dead-man contract inversion [assumed, bench].** With rc gone, its
  `sync_boot_state()` ONCE auto-commit (init.c:27102) disappears -> the dead-man
  becomes the SOLE committer/healer. `deadman-early` forks `/sbin/trial-deadman`
  first; commit-only-after-health-gate logic is harness work (offline-fixable).
- **D. /dev/watchdog single-open [assumed, bench].** `hw-wdt` (`wdtctl`) and a
  dead-man Layer-2 backstop cannot both own `/dev/watchdog`. Pick one owner on the
  bench (Layer-2 deferred here).
- **E. 18 raw `kill(1,SIG…)` reboot sites in rc [V-src].** rc's reboot/halt idiom
  signals PID1 assuming it is rc (init.c:26833/26966/27107, reboothalt 27223).
  With openrc-init as PID1 these need rc source patches (`rc_reboot_signal()`),
  per `[[prefer-openrc-over-custom-pid1]]`. Not on the early-init path but blocks
  clean reboot.
- **F. OpenRC-as-PID1 vs the bcm kernel's expectations [assumed, bench].** Does
  the closed bcm platform care that PID1 is `openrc-init` not `rc`? The graft
  early-init is launched by `bcm_boot_launcher` (a child), not by PID1 directly,
  so no `getpid()==1` dependency is visible in the OPEN paths — but the closed
  .ko/daemon internals are unaudited. This is THE bench gate.

## 5. Path to a (future, operator-aware) bench-boot

1. Cross-build OpenRC 0.56 (SDK arm-buildroot-linux-gnueabi gcc-10.3, glibc)
   with `--sysconfdir=/rom/etc`; stage `openrc-init`+`librc.so`+stock scripts.
2. Re-run `openrc-assemble.sh` with the stage -> coherent squashfs.
3. RE / write the open `start_lan` (Blocker B) or wire net-switch to webui.
4. Patch the 18 rc reboot sites (Blocker E).
5. Resolve C/D (dead-man harness + /dev/watchdog owner) offline.
6. Operator-gated bench trial (serial/JTAG): boot slot, watch
   bcm-platform module load, /data + nvram populate, br0 up, EnsureRadio radios,
   webui :80 — with the dead-man + ONCE + `/sbin/init` symlink revert as rollback.

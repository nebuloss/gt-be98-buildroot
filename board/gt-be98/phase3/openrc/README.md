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
- **v3 = v2 + SELF-DIAGNOSING persistent /data boot logging [V] (2026-06-07):**
  the v2 trial FAILED to boot with ZERO diagnostic — OpenRC does not run the ASUS
  `rc3.d` breadcrumb rail, so nothing recorded how far boot got. v3 adds 3
  persistent-`/data` logging layers so the re-trial reveals WHERE `openrc-init`
  dies, surviving the reboot/revert:
  1. **OpenRC built-in logger -> `/data`** — appended to the OpenRC `/rom/etc/rc.conf`:
     `rc_logger="YES"` + `rc_log_path="/data/openrc-rc.log"` (full
     service-execution log persisted to `/data`).
  2. **PID1 wrapper (`init-wrapper.sh`)** — the REAL OpenRC PID1 ELF is renamed
     `/sbin/openrc-init.real`; a tiny `#!/bin/sh` wrapper is installed at BOTH
     `/sbin/init` AND `/sbin/openrc-init`. It `mount`s `ubi:data /data` (ubifs,
     ext4 fallback), appends a `PID1-wrapper: kernel exec-d init … about to exec
     openrc-init` line + `$(cat /proc/uptime)` to `/data/openrc-boot.log`, dumps
     `dmesg > /data/openrc-dmesg-early.log`, then `exec /sbin/openrc-init.real
     "$@"`. Earliest-possible userspace capture (busybox `sh`/`mount`/`dmesg`/`cat`
     applets confirmed in the full base). No exec loop: the wrapper execs the
     `.real` ELF, never the other wrapper.
  3. **Per-service breadcrumb** — each of the 8 services prepends
     `echo "$(cat /proc/uptime) svc <name> START" >> /data/openrc-boot.log` as the
     first line of `start()` (webui is `command`-based, so its breadcrumb lives in
     `start_pre()`). Traces runlevel progress even if `rc_logger` inits late.
     `deadman-early` keeps mounting `/data` first.
  Re-ran `openrc-assemble.sh` on the same FULL br-0050 base (Image 1 of
  `GT-BE98_blob0035`, `69,894,144 B`, sha `a5179579…`). New squashfs
  `70,107,136 B` (66.86 MiB), under the slot-2 ceiling `71,106,560` (`999,424 B`
  headroom). **Image-diff vs FULL br-0050: ZERO removals; 174 adds (162 files/links
  + 12 dirs, all OpenRC-owned) + 1 mod (`/sbin/init`: `-> rc` ⇒ wrapper).** Graft
  byte-identical (`bcm_boot_launcher`, `wl.ko`, `dhd.ko`, `bcm_knvram.ko`,
  `/bin/nvram`, `S45bcm-base-drivers`, `/rom/etc/rc3.d`). **Safety net + new
  artifacts CONFIRMED present (sha-match base where applicable):
  `/usr/br/sbin/dropbearmulti`, `/sbin/trial-deadman`, `br-dropbear.sh`,
  `boot-breadcrumb.sh`, `trial-deadman.sh`, AND `/sbin/openrc-init.real` (ELF) +
  the wrapper `/sbin/init` + `/sbin/openrc-init` (shell).** pkgtb (br-0050
  boot-chain FIT, bootfs Image 0 byte-identical, sha `81f38fe0…`):
  `~/be98/artifacts-br/GT-BE98_openrc-init-v3_nand_squashfs.pkgtb`
  (`83,436,232 B`, sha `1e359107…`; rootfs Image 1 sha `17d30bb5…`). NOT flashed.
  **This is the self-diagnosing open-init for the re-trial.**
- **v4 = v3 + the early-load fix [V] (2026-06-07):** the v3 trial proved
  `openrc-init.real` EXEC'd but DIED before any service (empty rc.log). v4 placed
  `librc.so.1`+`libeinfo.so.1` ALSO in `/lib` (the loader's always-searched dir;
  merlin has no `/etc/ld.so.cache`), pre-built `/etc/ld.so.cache`, and redirected
  `openrc-init.real`'s own stdout+stderr to `/data/openrc-init-out.log`. pkgtb
  `~/be98/artifacts-br/GT-BE98_openrc-init-v4_nand_squashfs.pkgtb` (`83,440,328 B`).
  Commit `6924c9c`.
- **v5 = v4 + THE /run FIX [V] (2026-06-07) — CONCLUSIVE ROOT CAUSE.** v4
  source+strace diagnosis: `openrc-init` loops forever on
  `fopen("/run/openrc/init.ctl")` — OpenRC's `RC_INIT_FIFO` is hardcoded to `/run`
  on Linux (`src/librc/rc.h`). The merlin RO-squashfs root has **NO `/run`**
  (`/var->tmp/var`, `/etc->tmp/etc`; fstab mounts only proc/var/mnt/sys — verified:
  base has no `/run` dir, fstab has no `/run` line). OpenRC's
  `/usr/libexec/rc/sh/init.sh` (sysinit `do_sysinit`) **ABORTS** when `/run` is
  absent (`"The /run directory does not exist. Unable to continue."`) → no service
  runs (empty rc.log) → `init()` returns → `mkfifo`/`fopen(/run/openrc/init.ctl)`
  ENOENT loops forever, filling `/data`. THE FIX (delta on v4):
  1. `openrc-assemble.sh` bakes an empty `/run` (0755) into the squashfs so
     `init.sh`'s `[ -d /run ]` passes.
  2. `init-wrapper.sh` (PID1) pre-mounts `tmpfs /run` + creates `/run/openrc`
     + `/run/lock` just before `exec openrc-init.real`, so the FIFO can be created;
     `init.sh` sees `/run` already mounted (`mountinfo -q /run`) and skips re-mount.
  3. belt-and-suspenders `tmpfs /run` line appended to `/rom/etc/fstab`.
  All v4 fixes KEPT (librc/libeinfo in `/lib`, ld.so.cache, 3-layer `/data` logging,
  wrapper stderr-redirect). Re-assembled on the FULL br-0050 base (Image 1 of
  `GT-BE98_blob0035`, `69,894,144 B`, sha `a5179579…`). New squashfs
  `70,111,232 B` (66.86 MiB), under the slot-2 ceiling `71,106,560`
  (`995,328 B` headroom; +4,096 B vs v4 = the `/run` dir block + fstab line).
  **Image-diff vs FULL br-0050: ZERO removals; 179 adds (all OpenRC-owned + the
  baked `/run`); 3 mods — `/sbin/init` (symlink→`rc` ⇒ wrapper), `/rom/etc/fstab`
  (+`tmpfs /run` line), `tmp/etc/ld.so.cache` (dangling symlink ⇒ compiled cache).**
  Graft byte-identical (`bcm_boot_launcher`, `nvram`, `wl.ko`, `dhd.ko`,
  `bcm_knvram.ko`, full `/rom/etc/rc3.d`). Safety net byte-identical to base
  (`/usr/br/sbin/dropbearmulti`, `/sbin/trial-deadman`); `/run` baked + wrapper
  `/run` mount + `librc.so.1`/`libeinfo.so.1` in `/lib` all confirmed present.
  pkgtb (br-0050 boot-chain FIT, bootfs Image 0 byte-identical, sha `81f38fe0…`):
  `~/be98/artifacts-br/GT-BE98_openrc-init-v5_nand_squashfs.pkgtb`
  (`83,440,328 B`, sha `38959617…`; rootfs Image 1 sha `eddd5bed…`). NOT flashed.
  **This SHOULD let OpenRC sysinit proceed → services run → `openrc-init` gets its
  FIFO → boots reachable. The conclusive open-init for the re-trial.**
- **v6 = v5 + a COMMAND-CAPABLE OpenRC shell [V] (2026-06-07).** v5 trial
  result (from /data logs): the /run fix WORKED — OpenRC 0.56 boots, mounts
  /proc, caches deps, runs sysinit→boot→default (`rc default logging stopped`),
  but EVERY service failed `command: not found`
  (`openrc-run.sh: line 292/407`, `init.sh: line 22`) and a misleading
  `md5sum is missing`. ROOT CAUSE (confirmed by extracting the merlin
  `/bin/busybox` from the base): it is **BusyBox v1.25.1 built WITHOUT
  `CONFIG_ASH_CMDCMD`** → the ash `command` builtin is ABSENT
  (`busybox sh -c 'command -v ls'` → `command: not found`). The `md5sum is
  missing` was a *symptom*, not real: `init.sh:15` does `command -v md5sum`,
  which errored on the missing builtin and fell to the eerror; the merlin
  busybox DOES carry the `md5sum` applet and `/usr/bin/md5sum → ../../bin/busybox`
  exists. **THE FIX (graft-safe, NOT a global busybox swap):** an applet diff
  showed the merlin busybox has **25 applets the Buildroot busybox lacks**
  (`depmod, bash, logread, nc, ntpd, zcip, blockdev, chpasswd,
  add-shell/remove-shell, mkfs.vfat, traceroute6, …`) that the closed graft
  early-init may invoke → replacing `/bin/busybox` globally is UNSAFE. Instead
  v6 installs the from-source Buildroot **busybox 1.37.0**
  (`CONFIG_ASH_CMDCMD=y` + `CONFIG_MD5SUM=y`; built in `output-openrc-init`,
  stripped 874,212 B, max `GLIBC_2.28` ≤ merlin glibc 2.32 — ABI-compatible) as
  a SEPARATE `/bin/busybox.openrc`, and repoints ONLY OpenRC's own
  directly-exec'd librcdir `#!/bin/sh` scripts at it via
  `#!/bin/busybox.openrc sh` (6 scripts: openrc-run.sh, init.sh, init-early.sh,
  gendepends.sh, binfmt.sh, cgroup-release-agent.sh). `openrc-run` (C) `execl()`s
  `openrc-run.sh`, so EVERY service (8 custom + stock VFS, all
  `#!/sbin/openrc-run`) inherits the command-capable shell; init.sh/init-early.sh
  are exec'd the same way. The merlin `/bin/sh` + every graft `#!/bin/sh` script
  are byte-UNTOUCHED, and `md5sum` stays reachable via `/usr/bin/md5sum`.
  **Minor fixes:** (1) bake static `/rom/etc/{group,passwd}` incl. `daemon:x:1:`
  (the merlin rootfs has NO group db — `/etc/{group,passwd} → /var/*` were
  runtime-built by ASUS rc's `setup_passwd`, gone under OpenRC → `checkpath:
  owner root:daemon not found`); etc-farm's `for s in /rom/etc/*` loop symlinks
  `/etc/{group,passwd}` → them, and `/rom` is never shadowed by `mount -a`'s
  tmpfs `/var`. (2) bake `/tmp/etc/fstab → /rom/etc/fstab` so `init.sh`
  do_sysinit's `fstabinfo --mount /proc//run` finds `/etc/fstab` BEFORE etc-farm
  runs (v5's `/etc/fstab does not exist` was a non-fatal do_sysinit warning).
  All v5 fixes KEPT. **Image-diff vs FULL br-0050: ZERO removals; 185 adds (all
  OpenRC-owned + `/bin/busybox.openrc`, `/run`, `/rom/etc/{group,passwd}`,
  `/tmp/etc/fstab`); mods = `/sbin/init` (symlink→wrapper), `/rom/etc/fstab`
  (+tmpfs /run line), `tmp/etc/ld.so.cache` (dangling symlink→compiled cache).**
  Graft byte-identical (`bcm_boot_launcher`, `nvram`, `wl.ko`, `dhd.ko`,
  `bcm_knvram.ko`, `wdtctl`, full `/rom/etc/rc3.d`); **merlin `/bin/busybox`
  byte-IDENTICAL** (not touched); safety net byte-identical
  (`/usr/br/sbin/dropbearmulti`, `/sbin/trial-deadman`). **Verified the OpenRC
  shell now HAS `command`** (`busybox.openrc sh -c 'command -v command'` → OK,
  loads against the merlin libc in the v6 FS) and **`md5sum` reachable**
  (`/usr/bin/md5sum → busybox`; applet present). New squashfs `70,500,352 B`
  (67.23 MiB), under the slot-2 ceiling `71,106,560` (`606,208 B` headroom).
  pkgtb (br-0050 boot-chain FIT, bootfs Image 0 byte-identical, sha `81f38fe0…`):
  `~/be98/artifacts-br/GT-BE98_openrc-init-v6_nand_squashfs.pkgtb`
  (`83,829,448 B`, sha `2656b66a…`; rootfs Image 1 sha `341cd071…`). NOT flashed.
  **This SHOULD let OpenRC's services actually run → network/sshd → reachable.**
- **v7 = v6 + guaranteed reset-on-hang + early reachability [V-bin] (2026-06-07).**
  v6 booted-further but HUNG hard-unreachable. v7 armed the SoC HW watchdog in the
  PID1 wrapper in DIRECT, NON-petting mode (`wdtctl -t 240 start`, no `-d`/wdtd) so
  ANY hang resets → committed slot1; dropped the petting `hw-wdt` + the v6
  `net-switch` stub from the runlevels; added `net-lan` (config_switch +
  config_extwan + br0 + management IP + sshd :2222/:2223) to the boot runlevel.
  pkgtb `…_openrc-init-v7_…` (`83,833,544 B`).
  **v7 TRIAL RESULT (the win + the gap):** open-init booted FULLY — OpenRC
  sysinit→boot→default, bcm_boot_launcher graft drivers, net-lan, sshd, wifi-glue
  all ran (blocker F PASSED). BUT UNREACHABLE: net-lan did config_switch +
  config_extwan + `brctl addbr br0` + `ip addr 10.0.0.8` (all logged `[ok]`) yet
  **NO traffic passed** (never reachable on slot2, 2 trials). On Broadcom, br0 + ip
  is NOT enough: the HW flow-accelerator/runner datapath (eth ↔ bridge ↔ CPU) must
  be configured, which the ASUS rc START state does AFTER the bridge comes up.
- **v8 = v7 + the REAL Broadcom LAN datapath [V-bin] (2026-06-08).** ★The v7 gap
  fixed.★ DIAGNOSED on the LIVE working br-0045 (read-only capture; sw_mode=3
  AP/bridge) cross-referenced with the rc source (`rc/lan.c:start_lan`,
  `rc/init.c:26594..26613` START state, `rc/sysdeps/init-broadcom.c:fc_init`). The
  runner modules (`pktrunner`, `bcm_enet`, `pktflow`, `cmdlist`, `rdpa*`, `bdmf`)
  are ALREADY loaded by `bcm_boot_launcher` (bcm-platform) — present since v2. What
  v7's net-lan was MISSING (the eth↔br0↔CPU datapath) is THREE steps the rc START
  state does after the bridge is up, all confirmed live on br-0045:
  1. **ALLMULTI on br0 + every member.** `start_lan` brings the bridge up via
     `ifconfig(lan_ifname, IFUP|IFF_ALLMULTI, …)` and members run ALLMULTI too
     (live: `ifconfig br0`/`eth0` → `UP BROADCAST RUNNING ALLMULTI`). The
     bcm_enet+runner datapath floods/forwards to the CPU port via ALLMULTI; v7's
     `ip link set up` (NO ALLMULTI) left the runner with no CPU bridging.
  2. **`fc enable`** — `start_lan`'s `fc_init()` runs `fc enable` (flow-cache HW
     accelerator) when `!is_routing_enabled()` (AP mode). Live: `fcctl status` →
     `HW Acceleration <Enabled>`, `fc_disable=0`. (`/bin/fc → fcctl`.)
  3. **`rtpolicy auto ALL`** — rc `init_main` START state (init.c:26613, the
     `RTCONFIG_HND_ROUTER_BE_4916` step right after `start_lan`) applies the runner
     runtime policy from `/etc/rt_policy_info.d/`. `runner_disable=0`.
  net-lan now: bridge + members UP with ALLMULTI (`ifconfig … up allmulti`, IP set
  in the same `ifconfig` like rc), then `fc enable` + `rtpolicy auto ALL` (each
  nvram-gated on `fc_disable`/`runner_disable`), then sshd :2222/:2223.
  **start-stop-daemon fix:** OpenRC builds its OWN `/sbin/start-stop-daemon` +
  `/sbin/supervise-daemon` (the helpers `openrc-run.sh` uses for `command_background`
  services like webui), but v7's `OPENRC_BINS` never copied them. v8 adds both to
  the copy list (from-source OpenRC, byte-matching the rest). **Minor fixes:**
  etc-farm now writes `fstab`/`hosts`/`mtab`/`resolv.conf` to the TMPFS
  (`/tmp/etc/*`, removing the baked `/tmp/etc/fstab → /rom/etc/fstab` RO symlink
  first) instead of through a symlink into RO `/rom/etc`; bcm-knvram quieted to use
  the EXACT `/data` mount path deadman-early uses (ubifs `ubi:data` → ext4
  `/dev/data` fallback, both `2>/dev/null`). ALL v7 fixes KEPT (non-petting
  `wdtctl -t 240`, `/run` tmpfs, busybox.openrc command-shell, librc/libeinfo in
  `/lib` + ld.so.cache, `/data` logging, :2223 rescue, the 8+ services). Re-assembled
  on the FULL br-0050 base (Image 1 of `GT-BE98_blob0035`, `69,894,144 B`, sha
  `a5179579…`). New squashfs `70,545,408 B` (67.28 MiB), under the slot-2 ceiling
  `71,106,560` (`561,152 B` headroom). **Image-diff vs FULL br-0050: ZERO removals;
  185 adds (all OpenRC-owned + `/sbin/{start-stop,supervise}-daemon`, `/run`,
  `/rom/etc/{group,passwd}`, `busybox.openrc`, `/tmp/etc/fstab`); exactly 3 mods —
  `/sbin/init` (symlink→`rc` ⇒ wrapper), `/rom/etc/fstab` (+tmpfs `/run` line),
  `/tmp/etc/ld.so.cache` (dangling symlink ⇒ compiled cache).** Graft byte-IDENTICAL
  (`bcm_boot_launcher`, `nvram`, `wdtctl`, `bcm_knvram.ko`, `wl.ko`, `dhd.ko`, `fc`,
  `fcctl`, `rtpolicy`, `ethswctl`, `vlanctl`, full `/rom/etc/rc3.d`); safety net
  present (`/usr/br/sbin/dropbearmulti`, `/sbin/trial-deadman` byte-identical to
  base, `br-dropbear.sh`, `trial-deadman.sh`). pkgtb (br-0050 boot-chain FIT, bootfs
  Image 0 byte-identical, sha `81f38fe0…`):
  `~/be98/artifacts-br/GT-BE98_openrc-init-v8_nand_squashfs.pkgtb`
  (`83,874,504 B`, sha `e5d20e38…`; rootfs Image 1 sha `ca9999e1…`). NOT flashed.
  **This SHOULD make the open-init REACHABLE — br0+ip plus the runner datapath
  (ALLMULTI + fc + rtpolicy) so eth ↔ br0 ↔ CPU actually passes traffic.**
- **v10 [V-bin] (2026-06-08, :2222 admin sshd FIX = faithful merlin replica).**
  v9 trial PROVED the open-init boots/networks/serves — `net-diag.log`: gateway
  ping PASS (0% loss), `:80` + `:2223` LISTENING — but `:2222` admin sshd did NOT
  bind. ROOT CAUSE: v9 launched `:2222` via the generic `start_dropbear` (a
  `/data` ed25519-hostkey dropbear with NO `authorized_keys`); the merlin
  `/usr/sbin/dropbear` (→`dropbearmulti`) defaults to
  `/etc/dropbear/dropbear_{ecdsa,ed25519,rsa}_host_key`, which under the open-init
  is an `/etc`-tmpfs symlink-farm into RO `/rom/etc` (no `dropbear` dir) → hostkeys
  absent → dropbear exits before binding, and the admin pubkey was never written
  where dropbear reads it. **FIX (captured READ-ONLY from br-0045's live `:2222`):**
  the merlin `:2222` = exact cmdline `dropbear -p 2222 -j -k` (no `-r` ⇒ default
  `/etc/dropbear` hostkeys; `-j`/`-k` disable local/remote port-forwarding), with
  `/etc/dropbear/dropbear_*_host_key` → SYMLINKS to `/jffs/.ssh/dropbear_*_host_key`
  (persistent, slot-shared; all 3 confirmed present on the device), and admin
  `authorized_keys` = `nvram get sshd_authkeys` written to `$HOME/.ssh/authorized_keys`
  (admin `HOME=/root`→`/tmp/home/root`; persistent copy at `/jffs/.ssh/authorized_keys`,
  262 B). The new `start_admin_dropbear()` in `net-lan` replaces any `/etc/dropbear`
  symlink with a real dir, symlinks the 3 `/jffs/.ssh` hostkeys, writes the nvram
  authkeys (fallback to `/jffs/.ssh/authorized_keys`), then launches the EXACT
  `dropbear -p 2222 -j -k` under a capped babysitter that only respawns while
  `:2222` is unbound (can't pile up / hang boot). `:2223` rescue + v9 self-diag
  KEPT (re-confirms `:2222` LISTENING next trial). Re-assembled on the SAME FULL
  br-0050 base (Image 1 of `GT-BE98_blob0035`, `69,894,144 B`, sha `a5179579…`).
  New squashfs `70,561,792 B` (67.29 MiB), under slot-2 ceiling `71,106,560`
  (`544,768 B` headroom). **Image-diff vs FULL br-0050: ZERO pure-path removals;
  188 adds; graft byte-IDENTICAL; bootfs Image 0 byte-identical (`81f38fe0…`).**
  Safety net present (`/usr/br/sbin/dropbearmulti`, `/sbin/trial-deadman`,
  `br-dropbear.sh`, `S26trial-deadman`, `S28br-dropbear`). pkgtb:
  `~/be98/artifacts-br/GT-BE98_openrc-init-v10_nand_squashfs.pkgtb`
  (`83,890,884 B`, sha `d2aad9b0…`; rootfs Image 1 sha `ba4db57c…`). NOT flashed.
  **This SHOULD make the open-init FULLY reachable on `:2222` with the admin key
  (same key as br-0045), in addition to the v9-proven `:80` + `:2223`.**
- **v11 [V-bin] (2026-06-08, the ONE FIX — admin `authorized_keys` write now
  succeeds).** v10 got `:2222` dropbear LISTENING but the boot log showed
  `can't create /root/.ssh/authorized_keys: nonexistent directory` → no admin key
  loaded → key-auth rejected. **ROOT CAUSE (re-confirmed READ-ONLY on br-0045's
  live `:2222`, no key material read):** `/etc/passwd` =
  `admin:x:0:0:admin:/root:/bin/sh` (HOME=`/root`), and `/root` is a SYMLINK →
  `tmp/home/root` on tmpfs. Under the open-init the symlink TARGET `/tmp/home/root`
  does NOT exist (etc-farm created `/tmp/home` but not `/tmp/home/root`), so `/root`
  is a DANGLING symlink and `mkdir -p /root/.ssh` refuses to create through it
  → "nonexistent directory". **FIX (two tiny edits):** (1) `etc-farm` now
  `mkdir -p /tmp/home/root` so `/root` resolves to a real dir from early boot;
  (2) `net-lan start_admin_dropbear` now, BEFORE writing authkeys, resolves
  `readlink -f $HOME` (and `/root`) and `mkdir -p` the symlink TARGET, then
  `mkdir -p /root/.ssh` AND `"$HOME/.ssh"` (chmod 700), and writes
  `nvram get sshd_authkeys` (fallback `/jffs/.ssh/authorized_keys`) to BOTH
  resolved `authorized_keys` paths + keeps the persistent `/jffs/.ssh` copy,
  chmod 600 — so the existing `dropbear -p 2222 -j -k` finds the admin key.
  EVERYTHING else from v10 KEPT (`:2222` merlin cmdline + `/jffs` hostkeys,
  `:2223` rescue, v8 datapath, v9 net-diag). Re-assembled on the SAME FULL br-0050
  base (rootfs.img `69,894,144 B`, sha `a5179579…`; itb sha `81f38fe0…`). New
  squashfs `70,561,792 B` (67.29 MiB), under slot-2 ceiling `71,106,560`
  (`544,768 B` headroom), sha `40797e62…`. **Image-diff vs FULL br-0050: ZERO
  removals; 188 adds; graft byte-IDENTICAL (`nvram`, `wdtctl`,
  `bcm_boot_launcher`, `ethswctl`, `vlanctl`, `rtpolicy`, `fcctl`, `fc`,
  `dropbearmulti`, `trial-deadman`, `wl.ko`/`dhd.ko`/`bcm_knvram.ko`); bootfs
  Image 0 byte-identical (`81f38fe0…`).** Safety net present (`/usr/br/sbin/
  dropbearmulti`, `/sbin/trial-deadman`, `br-dropbear.sh`, `S26trial-deadman`,
  `S28br-dropbear`). pkgtb:
  `~/be98/artifacts-br/GT-BE98_openrc-init-v11_nand_squashfs.pkgtb`
  (`83,890,884 B`, sha `a93cb91a…`; rootfs Image 1 sha `40797e62…`). NOT flashed.
  **This SHOULD make the open-init FULLY reachable on `:2222` with the admin key
  — the v10 authkeys-write failure is fixed.**
- **v12 [V-bin] (2026-06-08, the LAST gap — admin key PERMS/OWNERSHIP).** v11 got
  `:2222` LISTENING + authkeys WRITTEN + datapath PASS, but dropbear v2025.88
  REJECTED the admin key. **ROOT CAUSE (from the merlin dropbear src
  `src/svr-authpubkey.c` `checkpubkeyperms()`/`checkfileperm()` + br-0045 perms
  captured READ-ONLY, NO key bytes):** dropbear walks the auth path UP from
  `authorized_keys` to the user's homedir (`pw_dir=/root`) and refuses ANY node
  (`~/.ssh/authorized_keys`, `~/.ssh`, `~`) that is owned by neither the user nor
  root OR is group/other-writable (`st_mode & (S_IWGRP|S_IWOTH)`). The open-init
  runs with **umask 0000**, so every bare `mkdir -p` in v11 created the `.ssh`
  dirs mode **0777** (group+other writable) → "must be owned by user or root, and
  not writable by group or others" → key REJECTED. **br-0045's WORKING chain
  (captured READ-ONLY, modes/owners ONLY):** `/tmp` `drwxrwxrwx`, `/tmp/home`
  `drwxr-xr-x`(755), `/tmp/home/root` `drwx------`(**700**), `.ssh`
  `drwx------`(**700**), `authorized_keys` `-rw-------`(**600**, 262 B) — all owner
  `admin:root` = **uid0:gid0**; `/root` → symlink `tmp/home/root`. The walk STOPS
  at `pw_dir=/root`, so `/tmp`/`/tmp/home` above it are NOT checked (why br-0045's
  world-writable `/tmp` is fine). **FIX (`net-lan start_admin_dropbear`):** explicit
  `chown 0:0` + `chmod 700` on the homedir (`/root`, `$HOME`, resolved
  `/tmp/home/root`) AND `.ssh`, `chmod 600` + `chown 0:0` on `authorized_keys` —
  never relying on umask — so the whole walked chain is EXACTLY br-0045's
  700/700/600 uid0:gid0. **Instrumentation (definitive next trial):** (a) dump
  `ls -lad` of the walked chain + `authorized_keys` perms/size (NO content) to
  `/data/net-diag.log`; (b) a SECOND verbose dropbear on debug port `:2229` with
  `-E -F -v` (—`-E` REQUIRED: this build has `DEBUG_TRACE 0`, so the perm-reject
  line reaches stderr ONLY with `-E`/`!usingsyslog`, per `svr-session.c
  svr_dropbear_log`) → `/data/dropbear-auth.log` capturing the EXACT auth verdict.
  Everything from v11 KEPT (`:2222` merlin cmdline + `/jffs` hostkeys, `:2223`
  rescue, v8 datapath, v9 net-diag). Re-assembled on the SAME FULL br-0050 base
  (rootfs.img `69,894,144 B`, sha `a5179579…`; itb sha `81f38fe0…`). New squashfs
  `70,565,888 B` (67.30 MiB), under slot-2 ceiling `71,106,560` (`540,672 B`
  headroom), sha `704fa4c9…`. **Image-diff vs FULL br-0050: ZERO graft removals
  (only the 2 expected mods — `/sbin/init` symlink→wrapper, `tmp/etc/ld.so.cache`
  symlink→compiled cache); 190 OpenRC-owned adds; graft byte-IDENTICAL (`nvram`,
  `wdtctl`, `bcm_boot_launcher`, `/usr/sbin/dropbear` :2222 admin binary,
  `dropbearmulti`, `trial-deadman`, `busybox`, `wl.ko`/`dhd.ko`/`bcm_knvram.ko`);
  bootfs Image 0 byte-identical (`81f38fe0…`).** pkgtb:
  `~/be98/artifacts-br/GT-BE98_openrc-init-v12_nand_squashfs.pkgtb`
  (`83,894,980 B`, sha `39a3522b…`; rootfs Image 1 sha `704fa4c9…`). NOT flashed.
  **This SHOULD make the admin key ACCEPTED on `:2222`; `:2229` + `net-diag.log`
  make the verdict definitive if not.**
- **v13 [V-bin] (2026-06-08, the LAST gap — admin key still rejected on `:2222`).**
  v12 got `:2222` LISTENING, perms EXACTLY br-0045's (700/700/600 uid0:gid0),
  datapath PASS, `:80` reachable — but the admin key was STILL rejected. **Two
  gaps closed (both diagnosed by READing br-0045 READ-ONLY — sha/byte-counts ONLY,
  NO key bytes):**
  **(a) authorized_keys CONTENT drift → BYTE-MATCH.** br-0045
  `/tmp/home/root/.ssh/authorized_keys` = **262 B, 2 lines (LF@80,161), sha256
  `6a09e22ceb71274f6b680b5037202f6d69d0b591edcfc4c5127362ee187d6364`**. v12 wrote
  the key from `nvram get sshd_authkeys` via `printf '%s\n'`, but the nvram value
  does NOT byte-reproduce the file: raw `nvram get` = **263 B, 1 trailing LF, sha
  `01d03d09…`**; even strip-trailing-LF = 262 B but sha `d319f33d…` with **3 LFs**
  (first differing byte at char 81 = the file's first LF — nvram mangles the
  INTERNAL newlines). So nvram can NEVER byte-match → dropbear saw a key string
  that didn't match → reject. **FIX (`net-lan start_admin_dropbear`):** prefer the
  AUTHORITATIVE source — `/jffs/.ssh/authorized_keys`, which on br-0045 is
  BYTE-IDENTICAL to the live key file (same sha `6a09e22c…`, 262 B, 2 lines; the
  slot-shared source of truth `dropbear -j -k` reads). Copy it verbatim (no
  transform); only if `/jffs` is ABSENT fall back to nvram (normalized
  `tr -d '\r'` + one trailing LF, best-effort). After writing, VERIFY `sha256sum`
  + `wc -c` vs the embedded br-0045 target and log
  `RESULT: PASS/FAIL authkeys byte-match (mine=NNN sha=… br0045=262 sha=6a09e22c…)`
  (counts/sha ONLY) to `/data/net-diag.log`.
  **(b) auth instrumentation was DEAD → FIXED.** v12's debug dropbear launched as
  `dropbear -E -F -v`, but **`-v` is INVALID on dropbear v2025.88** — it prints the
  usage text and EXITS, so `:2229` never bound and NO auth verdict was ever
  captured. **FIX:** launch `dropbear -E -F -p 2229` (drop `-v`); `-E` still routes
  the pubkey-auth verdict / perm-reject line to stderr → `/data/dropbear-auth.log`
  (e.g. "bad owner or permissions on /tmp/home/root/.ssh", "pubkey auth
  succeeded/failed for admin"). Everything from v12 KEPT (`:2222` merlin cmdline +
  `/jffs` hostkeys, `:2223` rescue, v8 datapath, v9 net-diag, v12 perms-fix +
  perms dump). Re-assembled on the SAME FULL br-0050 base (rootfs.img
  `69,894,144 B`, sha `a5179579…`; itb sha `81f38fe0…`). New squashfs
  `70,565,888 B`, under slot-2 ceiling `71,106,560` (`540,672 B` headroom), sha
  `d61cd14e…`. **Image-diff vs FULL br-0050: ZERO graft removals (only the 2
  expected type-changes — `/sbin/init` symlink→wrapper, `tmp/etc/ld.so.cache`
  symlink→compiled cache); 190 OpenRC-owned adds; of 3,215 common files exactly 1
  differs (`/rom/etc/fstab`, the intended v5 `tmpfs /run` line) — every graft
  object (`nvram`, `wdtctl`, `bcm_boot_launcher`, `/usr/sbin/dropbear`,
  `dropbearmulti`, `wl.ko`/`dhd.ko`/`bcm_knvram.ko`) byte-IDENTICAL; bootfs Image 0
  byte-identical (`81f38fe0…`).** pkgtb:
  `~/be98/artifacts-br/GT-BE98_openrc-init-v13_nand_squashfs.pkgtb`
  (`83,894,980 B`, sha `eae507ff…`; rootfs Image 1 sha `d61cd14e…`). NOT flashed.
  **The `:2222` admin key should now be ACCEPTED (byte-identical key + correct
  perms); if not, `:2229`'s now-WORKING `/data/dropbear-auth.log` carries the exact
  reject reason and `net-diag.log`'s `RESULT:` line confirms the byte-match.**
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

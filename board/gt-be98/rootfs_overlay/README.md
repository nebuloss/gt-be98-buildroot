# gt-be98 from-scratch rootfs overlay (busybox-init bring-up)

This overlay populates the **fully-generated** `gt-be98_defconfig` rootfs (Buildroot
`BR2_INIT_BUSYBOX`) with the init wiring needed to boot the box to a **reachable**
state. It is the busybox-init port of the *committable essence* of the proven
OpenRC open-init (`board/gt-be98/phase3/openrc/init.d/`, validated v22 — externally
reachable + committable), stripped of all trial/diagnostic instrumentation.

## Boot sequence (busybox `/etc/init.d/rcS` runs `S??*` in order)

| Script           | Role                                                                 |
|------------------|---------------------------------------------------------------------|
| `S10bcm-knvram`  | mount `/data` (ubifs ubi:data) + `insmod bcm_knvram.ko`              |
| `S15bcm-platform`| `bcm_boot_launcher start` → closed `rc3.d` S25-S50 (datapath .ko, nvram, wl/dhd) |
| `S40lan`         | `br0` over `lan_ifnames` + LAN IP + **default route** (reachability) |
| `S50dropbear`    | admin SSH on **:2222**, key-auth (overrides stock Buildroot :22)     |

`S15bcm-platform` reuses the closed `bcm_boot_launcher` verbatim — it replicates
~90% of the ASUS rc graft early-init (mounts, nvram kernelset, the HW-datapath
`.ko` load order, wl/dhd), so we never reimplement the closed datapath.

The default route in `S40lan` is the **v21 inbound-reachability fix**: without a
default gateway the bcm stack drops cross-subnet inbound SYNs before the socket.

## Provenance / faithfulness

Every script is a 1:1 de-instrumented port of a proven OpenRC service:
`S10bcm-knvram`←`bcm-knvram`, `S15bcm-platform`←`bcm-platform`,
`S40lan`+`S50dropbear`←`net-lan` (committable core only). Dropped from the port:
the trial-only debug dropbears (:2229/:2230 `-E`), SYN counters, the br-0045
authkey byte-match, `/data` diagnostics, and the non-petting watchdog (those are
trial-harness scaffolding, not a committed baseline).

## Known gaps / owed work (NOT yet resolved)

- **NOT yet device-validated.** These scripts are build-ready (build on dev-build),
  but no flash/boot trial has been run (device validation deferred by operator).
- **bcm_boot_launcher + closed `.ko` must be present.** A pure from-scratch rootfs
  must ship the userspace blob that provides `/bin/bcm_boot_launcher` + `/rom/etc/rc3.d`
  (currently via `gt-be98-userspace-base`) and the kernel modules under
  `/lib/modules/4.19.294/`. `S15bcm-platform`/`S10bcm-knvram` warn (don't fail) if absent.
- **First-boot nvram seeding.** With an empty `/data`, nvram is empty → `S40lan`
  falls back to the merlin defaults (10.0.0.8 / .254). Seeding a default nvram set
  (lan_ifnames etc.) on first boot is still owed.
- **wifi / webui / services** beyond reachable wired mgmt are not started here.

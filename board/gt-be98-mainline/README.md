# GT-BE98 mainline development OS

A Buildroot OS for the ASUS GT-BE98 (BCM4916, 4x A53, 2 GB) on the latest
stable mainline kernel, for driver work: OpenRC, ssh, the open Runner Ethernet
and Wi-Fi drivers as loadable modules, upstream debugging tools. It boots from
the same place and in the same way as the mainline diagnostic image
(open-ethernet `tools/mainline-boot`): a bootfs FIT in UBI volume 3 of slot 1,
trial-booted once from the stock slot.

- defconfig: `configs/gt-be98_mainline_defconfig`
- build: `board/gt-be98-mainline/build.sh` (build host only); `qemu-smoke.sh`
  boots the rootfs in QEMU (userspace check, no board hardware)
- output: `$OUT/images/ml-bootfs.itb`, `rootfs.squashfs` + `.sha256`,
  `ml-bootfs-pad30.itb` (size probe), `ml-bootfs.info`, `rootfs1-stub.squashfs`
- tests: `TESTPLAN.md`

## Contents

| Part | Version | From |
|---|---|---|
| Buildroot | 2026.08 (latest release, 4 Sep 2026, signature checked) | buildroot.org |
| toolchain | Buildroot internal: GCC 15.3, glibc 2.44, binutils (BR default), headers = the kernel | built |
| kernel | Linux 7.2.9 + the 33 patches of open-ethernet `kernel-patches/mainline` (all series files, README order) | kernel.org + package `gt-be98-open-ethernet` |
| init | OpenRC 0.56 (`openrc-init` as PID 1 after the initramfs) | |
| Ethernet | `bcm4916-runner.ko` (open-ethernet `driver/runner`) | package `gt-be98-open-ethernet` |
| Wi-Fi | `bca_pcie_ipc.ko` (open-wifi `driver/`, bench parameters, `bca_barpeek.ko` never installed) | package `gt-be98-open-wifi` |
| firmware | Runner/SerDes, XPHY, BCM84891L, 2x `rtecdc.bin`, `GT-BE98.nvm` (sha256-checked) | package `gt-be98-vendor-firmware`, local dirs |
| rescue | static BusyBox 1.38.0 (rescue initramfs only) | package `gt-be98-rescue-busybox` |
| userland | bash, coreutils, net-tools, findutils, grep, sed, gawk, util-linux, procps-ng, psmisc, kmod, iproute2, iputils, ethtool, nftables, conntrack-tools, tcpdump, iperf3, socat, netcat, rsync, curl, OpenSSH 10.5, OpenSSL 3.6 (libraries), dhcpcd 10.2, chrony 4.8, sysklogd 2.7, dnsmasq, iw 6.17, hostapd 2.12, wpa_supplicant 2.12, wireless-regdb, strace, gdbserver, perf, trace-cmd, memtool, pciutils, htop, lsof, nano, less | Buildroot |
| web UI | prebuilt `webui` (gt-be98-webui-go `mainline-os`), only if a path is given | package `gt-be98-webui` |

No BusyBox in the rootfs: BusyBox is only the rescue shell (and the optional
telnet lifeline, `/usr/libexec/gt-be98/busybox`).

## Build

On the build host (never on dev-code):

```sh
git clone -b mainline-os git@github.com:nebuloss/gt-be98-buildroot.git
cd gt-be98-buildroot
cp board/gt-be98-mainline/local.conf.example ~/.config/gt-be98-os/local.conf
$EDITOR ~/.config/gt-be98-os/local.conf        # paths, keys (never commit it)
rtk sh board/gt-be98-mainline/build.sh         # full build, ~1 h from scratch
```

The local configuration holds everything lab-specific: the Buildroot tree,
output and download dirs, the stock bootfs FIT, the firmware dirs, the SSH
public keys, the SSH host-key dir (generated on first use, so the box keeps
its host keys across rebuilds), optional static fallback addresses and a
remote syslog target. `build.sh` records its path in the Buildroot `.config`
(`BR2_PACKAGE_GT_BE98_OS_LOCAL_CONF`); after editing it, rerun `build.sh`
(it reconfigures when the file is newer than `.config`) and
`build.sh gt-be98-os-reinstall gt-be98-vendor-firmware-reinstall all`.

Private repositories (open-ethernet, open-wifi) are fetched over SSH at the
commits pinned in their `.mk` files. To build from a working tree instead
(driver iteration), put in `$OUT/local.mk`:

```make
GT_BE98_OPEN_ETHERNET_OVERRIDE_SRCDIR = /path/to/gt-be98-open-ethernet
GT_BE98_OPEN_WIFI_OVERRIDE_SRCDIR = /path/to/gt-be98-open-wifi
```

then `build.sh gt-be98-open-ethernet-rebuild all`.

### Kernel config

`linux/linux.config` is generated, never edited: `linux/gen-linux-config.sh`
runs `make allnoconfig`, merges the open-ethernet fragments the tested images
use (`gt-be98-mlboot.config`, `-s2`, `-pcie`, `-pcie-all`), then
`linux/gt-be98-os.config` (squashfs/loop/overlay, seccomp, cgroups,
namespaces, perf/ftrace/kprobes, netfilter and tc modules, USB storage), sets
the forced command line (stage-2 `cmdline-s2` + `pci=pcie_bus_safe
pcie_aspm=off`) and `CONFIG_INITRAMFS_SOURCE`, checks that every fragment line
survived, and saves the result with `savedefconfig`. To change the kernel
config: edit a fragment, `make linux-patch`, rerun the script (its header has
the command), commit `linux.config`. `--check` verifies the committed file.

## Image layout (decision: small FIT, rootfs from USB or HTTP; nothing on the NAND)

```
ml-bootfs.itb (UBI vol 3 = bootfs1, ~16 MB)   stock FIT structure, rebuilt by mkbootfs.py
 ├─ atf, uboot, fdt_uboot, vendor dtbs        unchanged from the stock bootfs
 ├─ kernel = Image.lzo                        Linux 7.2.9 + built-in initramfs:
 │                                              /init + static rescue BusyBox
 └─ fdt_mainline                              board DT (USB, watchdog, 4x PCIe, 256 MB MPM)
rootfs.squashfs (+ .sha256)                   the OS, served over HTTP or on a USB stick
```

`/init` (package/gt-be98-os/src/rescue/init):

1. USB power pins, USB-Ethernet lifeline (udhcpc, 45 s window), then
   bounded watchdog petting (`NET_WDT_MAX`, 300 s) while the rootfs loads;
2. a USB storage partition labelled `GTBE98-ROOT`: `/rootfs.squashfs` on it
   (vfat or ext4), or a complete ext4 root with `/sbin/init`, booted
   read-write (the persistent option);
3. otherwise `ROOTFS_URL` (+ `ROOTFS_URL.sha256`) over HTTP into RAM, sha256
   checked; `@DHCP_SERVER@` / `@DHCP_ROUTER@` in the URL are replaced by the
   lease values;
4. the squashfs is loop-mounted read-only at `/rom` with an overlayfs on a
   tmpfs (`/overlay`, which also holds the downloaded image), petting stops,
   `switch_root` into OpenRC, whose `gt-be98-watchdog` reopens the watchdog;
5. any failure: the stage-2 rescue (telnet on the USB address, no password,
   bounded petting, then a reset into stock).

History: the first image (IMAGE=initrd: the rootfs as a 29 MB "rootfs" image
inside the FIT, named to the kernel by `/chosen/linux,initrd-*`, 46 MB FIT)
never reached the kernel on the box on 2026-10-08 (post-code byte untouched),
while the 14.7 MB diagnostic FITs boot. A likely cause is the first-stage
loader: the TPL also reads the bootfs volume to start ATF + U-Boot
(`CONFIG_SPL_LOAD_FIT_ADDRESS` = `CONFIG_TPL_TEXT_BASE` + 0x2000000 =
0x7000000), with limits of its own. `ml-bootfs-pad30.itb` (the netroot FIT
padded to 30 MiB with an unreferenced image) probes that limit in one boot.
`IMAGE=initrd` stays available for a boot chain that accepts it.

Why not a UBI rootfs: it needs mainline brcmnand + UBI on this NAND, unproven,
and writes from mainline are forbidden (PERSISTENCE.md); the DT has no NAND
node at all.

### Size limits

| Limit | Value | Evidence |
|---|---|---|
| bootfs FIT | ≤ 16 MiB enforced for netroot (built: ~16.1 MB) | on the box: the ~16 MB netroot FIT boots, the 46 MB one did not reach the kernel; the pad30 probe (30 MiB) is not tested yet |
| kernel `image_size` (with BSS, built-in initramfs included) | < 0x2000000 − 0x200000 = 30 MiB | U-Boot reads the bootfs to `load_addr + 16 MiB` = 0x2000000 (`CONFIG_SYS_LOAD_ADDR` = 0x1000000, no `loadaddr` in the shipped default environment) and decompresses the kernel to 0x200000 |
| decompressed kernel | < 64 MiB | `CONFIG_SYS_BOOTM_LEN` of the shipped U-Boot = 0x4000000 (`mov w7, #0x4000000` at 0x102d030, the `unc_len` of the `bootm_decomp_image` call) |

To keep the kernel small: `CONFIG_RELR` (packed relocations, −2 MB), and the
tracing set is tracepoints + kprobe events + perf counters (no function
tracer, BPF or KALLSYMS_ALL).

### Flash space

The netroot FIT (~16 MB) is close to the stock bootfs (13.7 MB): vol 3 needs
a few more LEBs. Slot 1's rootfs volume (vol 4) is not used by this OS; U-Boot
only checks its squashfs magic before booting slot 1, so the build's
`rootfs1-stub.squashfs` (4 KiB) can replace it (operator decision; done on
2026-10-08, the old vol 4 is backed up on the build host).

## Boot, services, post-codes

Post-codes are written to `0xff802628[31:24]` by the `be98pc` earlycon from
"BE98PC xx" lines; nothing in this OS can change bits [23:0] (the `devmem` in
the rootfs refuses such a write).

| Code | Where | Meaning |
|---|---|---|
| c0..c5 | `/init` | `/init` runs, `/proc`, `/sys`, `/dev`+`/tmp`, command line, USB pins |
| c6 / c7 / c9 | `/init` | USB NIC found / address / boot-time watchdog petting started |
| d7 / d8 | `/init` | looking for a `GTBE98-ROOT` USB partition / found and mounted |
| d9 / da | `/init` | fetching the rootfs over HTTP / fetched, sha256 ok |
| f1 / f2 / f3 | `/init` | squashfs mounted / overlay mounted / `switch_root` to OpenRC |
| e0 e1 e2 e3 e4 e5 e6 | `/init` | rescue because: no rootfs source / squashfs mount failed / overlay failed / no `/sbin/init` / `RESCUE=1` / HTTP fetch failed / sha256 mismatch |
| e8 | `/init` | no lifeline address within 45 s (nothing pets: U-Boot's watchdog resets) |
| c8 / ca / ee | rescue | telnetd up / petting deadline reached / no USB bus |
| f4 | OpenRC boot | watchdog petting started (`gt-be98-watchdog`) |
| f5 / f6 | OpenRC | dhcpcd / sshd started |
| f7 / e7 | OpenRC | Runner module loaded / failed to load |
| fa | OpenRC | default runlevel reached (`gt-be98-boot-done`) |
| fb | watchdog daemon | healthy: an IPv4 address and sshd (or telnet) running; re-posted whenever a later code (a service restart) replaced it while healthy |
| fc | watchdog service | petting stopped by request: reset follows unless started again |
| fd | watchdog daemon | unhealthy for `GRACE` s: petting stopped, hardware reset follows |
| fe | OpenRC shutdown | clean reboot / poweroff |

Runlevels: **boot** `gt-be98-watchdog`, `gt-be98-netguard`, `gt-be98-persist`, `syslogd` (plus
OpenRC's own); **default** `dhcpcd`, `sshd`, `chronyd`, `gt-be98-drivers`,
`gt-be98-boot-done`. Installed, not enabled: `gt-be98-wifi`,
`gt-be98-telnet` (enabled automatically only when the image has no SSH key),
`dnsmasq`, `webui`.

### Watchdog policy

U-Boot arms the SoC watchdog before the kernel; an un-petted box resets into
the committed (stock) slot. `gt-be98-wdtd` opens `/dev/watchdog`
(`bcm7038_wdt`, NOWAYOUT) and pets it every 5 s:

- unconditionally until uptime `PROBATION` (180 s);
- then only while `gt-be98-health` passes: an IPv4 global address on some
  interface **and** sshd (or the telnet lifeline) running;
- after `GRACE` (300 s) of failed checks it stops petting (code fd) and the
  box resets ~30 s later. So a box nobody can reach goes back to stock by
  itself, at most ~8.5 min after boot, and a healthy box is never reset.
- `rc-service gt-be98-watchdog stop` resets the box (NOWAYOUT) unless it is
  started again within the timeout. `MODE=always` in
  `/etc/conf.d/gt-be98-watchdog` pets unconditionally (bench with physical
  access only).

### Network

`gt-be98-netguard` (boot runlevel) owns the base network policy: an
interface matching `rnr* eth* usb* enx*` is detached the moment anything
makes it a bridge port, and hairpin mode is turned off on every bridge port
(link events + a 5 s sweep). A bridge with only Wi-Fi interfaces (bcawl*) is
allowed. Runner ports get a **stable MAC** (`gt-be98-macaddr`): the board's
base MAC (`ethaddr` of the U-Boot environment, which the vendor U-Boot
exports into the Linux DT as `/uboot_env`), made locally administered, +N
for rnrN; set by `gt-be98-drivers` after each load and by the dhcpcd hook
`05-gt-be98-mac` if dhcpcd sees the port first. `RNR_MAC_BASE` in
`/etc/conf.d/gt-be98-drivers` overrides the base.

dhcpcd (manager mode) on the USB lifeline (`eth*`, `usb*`, `enx*`) and on
`rnr0` only; it picks up `rnr0` when the Runner module loads and a USB NIC
when it re-enumerates. Nothing is bridged (no loops through cabled ports, no
hairpin), IPv4 forwarding is off, and there is no firewall: sshd accepts
public keys only (`PasswordAuthentication no`, root has no password). Static
fallbacks for a bench without a DHCP server: `RNR0_FALLBACK`/`USB_FALLBACK`
in the local configuration. No udev: devtmpfs only; modules not built in are
loaded by the services (`modprobe`).

## Driver development

- Kernel tree with the series and the exact config: `$OUT/build/linux-7.2.9`.
  Out-of-tree build against it:
  `make -C $OUT/build/linux-7.2.9 ARCH=arm64 CROSS_COMPILE=$OUT/host/bin/aarch64-buildroot-linux-gnu- M=$PWD modules`
- On the box the rootfs is a RAM overlay, so a new module can be copied
  anywhere: `scp bcm4916-runner.ko root@box:/tmp/`, then either
  `RUNNER_KO=/tmp/bcm4916-runner.ko` in `/etc/conf.d/gt-be98-drivers` and
  `rc-service gt-be98-drivers restart`, or `rmmod bcm4916_runner;
  insmod /tmp/bcm4916-runner.ko flow_offload=1` by hand.
- debugfs is mounted (`/sys/kernel/debug/bcm4916-runner`, `bca/...`), tracefs
  at `/sys/kernel/tracing`; `perf`, `trace-cmd`, `strace`, `gdbserver`,
  `devmem`/`memtool` are installed.
- `oops=panic panic=1` stay on the forced command line (an oops reboots into
  stock). To keep the box up after an oops while debugging:
  `sysctl -w kernel.panic_on_oops=0`.
- `CONFIG_MODULE_FORCE_UNLOAD=y`: `rmmod -f` exists for a wedged module.

## Persistence

P1 is volatile by design: the rootfs is RAM, and the NAND is never written.
Logs persist only off the NAND:

- `gt-be98-persist`: a USB storage device labelled `GTBE98-DATA` (ext4 or
  vfat, second USB port) is mounted on `/data`; each boot logs to
  `/data/log/boot-NNNN/` (syslog, dmesg at boot and shutdown), and
  `/data/etc-overlay/` is copied over `/etc` at boot (persistent config);
- `SYSLOG_REMOTE`: every log line is also sent to a lab host over UDP.

The P2 design (read-only stock `/data`, promotion of the image to a
committed slot) is in `PERSISTENCE.md`.

## Safety rules this OS keeps

- No NAND node in the DT, no flash writes, no UBI attach.
- `0xff802628`: only bits [31:24] (post-codes); the rootfs `devmem` refuses
  any write that would change bits [23:0].
- The watchdog is never stopped: NOWAYOUT, `watchdog.stop_on_reboot=0`, and
  the petting is gated on health.
- PCIe core 1 shares its power domain with the Runner: kernel patch 0903 holds
  it; nothing in userspace touches PMB.
- Public repository: no addresses, MACs, host names, keys or blobs here; all
  of that is in the local configuration on the build host.

## Licences

Buildroot packages under their own licences (`make legal-info`). The kernel
patches and drivers are GPL-2.0. The vendor firmware is proprietary and not
redistributable: it is copied from local directories into the image only, and
the image must not be published.

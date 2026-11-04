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
| kernel | Linux 7.2.9 + the open-ethernet `kernel-patches/mainline` series files listed in `GT_BE98_OPEN_ETHERNET_SERIES` (README order; the build log prints the count) | kernel.org + package `gt-be98-open-ethernet` |
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

A **release image** (for someone else's box: no lab host keys, no web UI
password, no lab addresses) is built with `RELEASE=1` from
`release.conf.example` into a separate output directory, checked with
`release-check.sh`, and handed over privately only: `docs/RELEASE-BUILD.md`.

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
the forced command line (stage-2 `cmdline-s2` without `ignore_loglevel`,
`panic=5` instead of `panic=1`,
+ `loglevel=4 pci=pcie_bus_safe pcie_aspm=off`: a quiet UART console, since
every console line is written synchronously at ~87 us/char; post-codes are
written at KERN_CRIT so the be98pc earlycon still sees them) and `CONFIG_INITRAMFS_SOURCE`, checks that every fragment line
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
rootfs.squashfs (+ .sha256)                   the OS: in slot 1's UBI vol 4 "rootfs1" (NAND
                                              images), on a USB stick, or served over HTTP
```

`/init` (package/gt-be98-os/src/rescue/init):

1. USB power pins, bounded watchdog petting (`NET_WDT_MAX`, 300 s) while
   the rootfs loads (no network needed for 2 and 3);
2. a USB storage partition labelled `GTBE98-ROOT`: `/rootfs.squashfs` on it
   (vfat or ext4), or a complete ext4 root with `/sbin/init`, booted
   read-write (the persistent option);
3. slot 1's UBI volume `rootfs1` (vol 4; `NAND=ro`/`rw-jffs` images): UBI
   attached with nothing writable (`brcmnand.allow_write=0`, no UBI fence:
   the write gate refuses every write), the first `ROOTFS_SIZE` bytes copied
   into RAM and checked against `ROOTFS_SHA256` (both built into the
   initramfs by post-image.sh: an itb boots from vol 4 only the rootfs built
   with it; a new itb with an old vol 4 falls through to HTTP), UBI detached
   again, so nothing holds the NAND and `gt-be98-jffs` attaches it afresh
   with the write fence. Copy-to-RAM rather than ubiblock: the verified bytes
   are the mounted bytes, no volume stays open across the handover, and the
   RAM cost (~29 MB) is that of the HTTP path;
4. otherwise the USB-Ethernet lifeline (udhcpc, 45 s window) and
   `ROOTFS_URL` (+ `ROOTFS_URL.sha256`) over HTTP into RAM, sha256 checked
   (to test a new rootfs without reflashing vol 4); `@DHCP_SERVER@` /
   `@DHCP_ROUTER@` in the URL are replaced by the lease values;
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

### Flash space and flashing slot 1

Slot 1 holds the OS: vol 3 `bootfs1` = `ml-bootfs.itb` (~16 MB, 127 LEBs
used of 397 reserved), vol 4 `rootfs1` = `rootfs.squashfs` (~28.8 MB, 228
LEBs; given 265 LEBs = 32.1 MiB for growth). On this box's UBI device
(2024 LEBs, 306 free with vol 4 at its 9-LEB stub) that leaves 50 free LEBs;
vol 3 needs no resize. U-Boot only checks vol 4's squashfs magic, which the
rootfs has. Flash from STOCK with the kit (`nand-phase2-kit`: static
`ubirsvol`, `ubiupdatevol`, `stock-slot1-flash.sh`), the itb and the rootfs
built together (the itb carries the rootfs sha256):

```sh
cd /tmp/gtb && sha256sum -c SHA256SUMS
./stock-slot1-flash.sh --check rootfs.squashfs <rootfs sha256> ml-bootfs.itb <itb sha256>   # plan only
./stock-slot1-flash.sh         rootfs.squashfs <rootfs sha256> ml-bootfs.itb <itb sha256>
#   = ubirsvol /dev/ubi0 -n 4 -S 265; ubiupdatevol /dev/ubi0_4 rootfs.squashfs;
#     ubiupdatevol /dev/ubi0_3 ml-bootfs.itb; each read back and sha256-checked;
#     refuses when the UBI device lacks the free LEBs
bcm_bootstate 3; reboot
```

`qemu-slot1.sh` rehearses exactly this on the box's UBI device in nandsim
(the kit script, then the slot-1 boot with no network device at all).

For a release (an owner flashing from stock and going back), use
`docs/FLASHING.md` and its helper `flash/gt-be98-flash.sh` (kit:
`flash/build-flash-kit.sh`). It is the same procedure, with two additions:
it refuses unless stock runs from slot 2 and slot 2 is committed, and it
checks that the one-shot boot was armed.

## Boot, services, post-codes

Post-codes are written to `0xff802628[31:24]` by the `be98pc` earlycon from
"BE98PC xx" lines; nothing in this OS can change bits [23:0] (the `devmem` in
the rootfs refuses such a write).

| Code | Where | Meaning |
|---|---|---|
| c0..c5 | `/init` | `/init` runs, `/proc`, `/sys`, `/dev`+`/tmp`, command line, USB pins |
| c6 / c7 / c9 | `/init` | USB NIC found / address / boot-time watchdog petting started |
| d7 / d8 | `/init` | looking for a `GTBE98-ROOT` USB partition / found and mounted |
| db / dc | `/init` | reading UBI vol 4 `rootfs1` / copied, sha256 ok |
| d9 / da | `/init` | fetching the rootfs over HTTP / fetched, sha256 ok |
| e9 / eb | `/init` | UBI `rootfs1` unavailable (no NAND partition, attach failed, no volume, no expected sha256) / its sha256 does not match this image's rootfs (then HTTP is tried) |
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
`gt-be98-netconsole` (a no-op until a target is configured),
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
allowed. One exception, the wired LAN: a port listed in `LAN_PORTS`
(`/etc/conf.d/gt-be98-lan`) may be a port of `LAN_BRIDGE` (br-lan) and of no
other bridge, when it is `rnr1`, `rnr2` or `rnr3` and not the Wi-Fi trunk
port; `rnr0` never is, even listed (the uplink and management port, on the
owner's LAN: open-ethernet `docs/eth-lan-2026-11-02.md` §3). br-lan holds no
rnr0 member of any kind, so a LAN jack never shares a segment with the
uplink. `gt-be98-netguard --selftest` checks the verdicts (23 cases).

`gt-be98-lan` (NOT enabled by default, owner decision D16) builds the wired
LAN from `/etc/conf.d/gt-be98-lan`: `LAN_PORTS` (empty by default; `rnr1` =
the RTL8372's four 2.5G jacks, `rnr2` 1G, `rnr3` 10G) in `LAN_BRIDGE` with
STP on (`LAN_STP`), the ports' IPv4 addresses flushed, an optional
`LAN_ADDR` and DHCP server (`LAN_DHCP`, its own dnsmasq bound to the bridge,
never rnr0), the nft table `inet gt_be98_lan` (only replies, DNATed flows
and bridge-to-bridge traffic are forwarded into the bridge), and the
read-only switch monitor `rtl8372.ko` when rnr1 is a LAN port and the
module is installed (`BR2_PACKAGE_GT_BE98_OPEN_ETHERNET_RTL8372`, off by
default). The wired LAN leaves the box only routed: list the bridge in
`ROUTER_LANS` (`br-lan=192.168.50.1/24`) and a radio joins it with
`bridge=br-lan` in its hostapd config. Not verified on silicon: the bench
has only rnr0 cabled, and the RTL8372 is not set up by anything on mainline
yet (its uplink lane never locks; open-ethernet `docs/eth-lan-2026-11-02.md`
§0, §2.3).

#### Runner port MAC addresses

`gt-be98-macaddr` is the one policy, applied by `gt-be98-drivers` after each
load (ports still down) and by the dhcpcd hook `05-gt-be98-mac` if dhcpcd
sees a port first. For rnrN, the first that applies:

| Source | Address |
|---|---|
| override | `RNR_MAC<N>=aa:bb:cc:dd:ee:ff`: exactly that (must be unicast, non-zero) |
| base | `RNR_MAC_BASE=aa:bb:cc:dd:ee:ff`: the base made locally administered (first octet \|0x02), +N on the last octet; every port, rnr0 included |
| factory | the MAC the driver read from the DT: U-Boot fills `local-mac-address` of the `ethernet0` port from its `ethaddr`, the board's factory MAC that stock uses too (rnr0) |
| derived | U-Boot `ethaddr` (exported into the DT as `/uboot_env`), locally administered, +N |
| hash | a hash of the U-Boot identity values, locally administered, +N |

Default (no key set): rnr0 keeps its factory MAC, the other ports get the
derived address; all are stable across boots and driver reloads. An
explicit key wins over the DT MAC. Invalid values are ignored with a
warning (the next source applies).

The keys are read (never sourced) from `/etc/conf.d/gt-be98-drivers`, then
`/etc/conf.d/gt-be98-macaddr`, which wins (an empty key there clears one
from the first file). `gt-be98-macaddr` is the file the web UI writes; it
is in `ALLOW_PATHS`/`AUTOSAVE_WATCH` of `/etc/conf.d/gt-be98-jffs`, so it is
saved to `/jffs` (`gt-be98-save`, `gt-be98-autosave`) and restored before
the driver loads. `/etc/conf.d/gt-be98-drivers` itself is image-owned and
NOT persisted (a new image's driver defaults must not be masked by a saved
copy).

```sh
gt-be98-macaddr --status          # iface current wanted source factory
gt-be98-macaddr --apply [rnrN]    # apply now: link down, address, up, dhcpcd rebind
```

At runtime the address changes with the link down (the Runner driver has
no live address change; its `ndo_set_mac_address` rebuilds the parser DA
filters, the router MACs); `--apply` takes the link down and up again if it
was up, then `dhcpcd -n` so the lease follows the new client id (dhcpcd's
`clientid` is the MAC). The factory MAC is recorded in
`/run/gt-be98-macaddr/` while the driver's address is in place, so "reset to
factory" (remove the key, `--apply`) works after an override.

dhcpcd (manager mode) on the USB lifeline (`eth*`, `usb*`, `enx*`) and on
`rnr0` only; it picks up `rnr0` when the Runner module loads and a USB NIC
when it re-enumerates. The WAN mode (static, PPPoE, a VLAN, DHCPv6
prefix delegation) is `gt-be98-wan`, below; by default it changes none of
this. Nothing is bridged (no loops through cabled ports, no
hairpin), IPv4 forwarding is off, and there is no firewall: sshd accepts
public keys only (`PasswordAuthentication no`, root has no password). Static
fallbacks for a bench without a DHCP server: `RNR0_FALLBACK`/`USB_FALLBACK`
in the local configuration. No udev: devtmpfs only; modules not built in are
loaded by the services (`modprobe`).

### Wi-Fi access points and router mode

Both services are installed, NOT enabled; the web UI's Wi-Fi AP page
(webui-go, linux platform) writes their files and enables them with
`rc-update`. Standard interfaces only (nl80211 through hostapd/iw, iproute2,
nftables, dnsmasq): no driver internals or module parameters.

- `gt-be98-wifi`: loads `bca_pcie_ipc` and runs ONE hostapd for every radio
  (`hostapd -g /run/hostapd-global`, each radio added with `ADD
  bss_config=<phy>:<config>`; one process is what lets hostapd put the
  co-located 6 GHz BSSes in the 2.4/5 GHz Reduced Neighbor Report). Two
  sources, combinable on different radios: `WIFI_NETWORKS` (a network list,
  `/etc/hostapd/networks.conf.example`; `gt-be98-wifi-gen` renders one
  hostapd config per radio with `bss=` sections at sticky slots
  (`/etc/hostapd/wifi-slots`), an explicit `bssid=` per BSS (the
  firmware's mbss8 rule: index = last byte & 7, one per BSS of a radio,
  the radio address's included, all of a radio's secondaries in one
  block, per-radio locally administered prefix; on 6 GHz the secondaries
  are the first network's nontransmitted BSSIDs, and with
  `WIFI_ANCHOR_KEEP_BSSID=1` - the default since RC2 - that first network
  takes a locally administered block of its own, so 6 GHz carries 8
  networks; ⚠**upgrading to RC2 changes every existing 6 GHz network's
  BSSID once**; a network's own MAC per band: `bssid.<band>=`),
  `bridge=brwifi<id>`, the
  6 GHz rules (SAE-H2E, OWE or WPA3-Enterprise, PMF required) and `rnr=1`
  on 2.4/5 GHz; at most `WIFI_MAX_BSS` BSSes per radio, 1..8, unset = the
  count the driver advertises in `iw phy` (`#{ AP } <= N`, the firmware's
  own: 8 on this box), 4 when no radio states one; the value used is in
  `/run/gt-be98-wifi/max-bss`) and `HOSTAPD_CONFS` (ready-made
  configs, one per radio). Enterprise networks (`security=wpa2-eap`,
  `wpa3-eap` = WPA-EAP-SHA256 with PMF required, `wpa2-wpa3-eap`) relay
  802.1X/EAP to an external RADIUS server (`radius_server=<IP>`,
  `radius_port`, `radius_secret`, optional `radius_acct_*`); the image's
  hostapd is built with `BR2_PACKAGE_HOSTAPD_EAP` (RADIUS client and
  accounting; its integrated EAP/RADIUS server is compiled in but never
  configured). The secrets live only in the 0600 network list and the 0600
  generated configs, and no error message repeats one.
  `/etc/conf.d/gt-be98-wifi-ap` (web UI, parsed not sourced) overrides the
  image's values, so the image keeps owning `WIFI_ARGS`. The web UI writes
  `/etc/hostapd/hostapd-<bcawlN>.conf` (0600, `wmm_enabled=1`,
  `ctrl_interface=/run/hostapd`, `country_code` only when `iw reg reload`
  succeeds). `rc-service gt-be98-wifi reload` applies a change through the
  global control socket, the driver staying loaded: a further BSS (slot
  k >= 1) added, removed or changed is `ADD`ed/`REMOVE`d alone; a radio
  whose radio-wide lines, anchor BSS (slot 0) or ready-made config changed
  restarts alone; the process restarts only when it died or `HOSTAPD_ARGS`
  changed. hostapd log: `/var/log/hostapd.log`.
- `gt-be98-router` (`need gt-be98-wifi`): from `/etc/gt-be98-router/`
  (`router.conf`: `ROUTER_WAN`, `ROUTER_LANS="bcawl3=192.168.83.1/24 ..."`;
  `router.nft`; `dnsmasq.conf`) it puts each address on its Wi-Fi interface,
  loads `table ip gt_be98_router` (Wi-Fi LANs may reach anything, only
  replies and DNATed forwards come back into them; masquerade on every
  non-Wi-Fi output, since the box often has two default routes: the USB
  dongle `eth0`, preferred, and `rnr0`), policy-routes the Wi-Fi LANs by
  input interface (`ip rule iif bcawlN table 180`; table 180 = the WAN's
  default route, `unreachable` until it has one, plus `throw` routes for
  10/8, 172.16/12, 192.168/16 and the WAN subnet so local destinations use
  the main table; never a `from <subnet>` rule, which would capture
  dnsmasq's own replies; the dhcpcd hook `06-gt-be98-router` rebuilds it
  with `rc-service gt-be98-router reroute` when the WAN lease changes),
  sets `net.ipv4.ip_forward=1` and runs its own
  dnsmasq (DHCP + DNS bound to the Wi-Fi interfaces, upstream from
  `/etc/resolv.conf`; leases in `/run/gt-be98-router.leases`). It refuses a
  LAN that is not `bcawl*` or the wired LAN bridge (`gt-be98-lan`'s
  `LAN_BRIDGE`), a Wi-Fi/bridge WAN, or a LAN that is a bridge port; it
  bridges nothing itself, `gt-be98-netguard` still applies. The WAN's own
  link, address and routes are never touched (it may be the only management
  path). `stop` removes the addresses and rules it set, both tables, and
  turns forwarding off. hostapd always runs under `gt-be98-wifi` (`-B -P
  /run/hostapd-wifi.pid`), never by hand.
- Station (Wi-Fi uplink, client mode; design below).
- Persistence: `etc/hostapd`, `etc/conf.d/gt-be98-wifi-ap`,
  `etc/gt-be98-router` and the two runlevel links
  (`etc/runlevels/default/gt-be98-{wifi,router}`) are in `ALLOW_PATHS` and
  `AUTOSAVE_WATCH` (`/etc/conf.d/gt-be98-jffs`): restored by `gt-be98-jffs`
  in the boot runlevel, before the default runlevel starts the services.

### Wi-Fi station (uplink / client / repeater uplink)

Design (lane os-sta, 2026-11-02). The driver's station is box-verified with
hand-written configs (open-wifi `docs/STA-WDS-2026-10-29.md`; stawds arms
S1 WPA2, S2 WPA3-SAE, S3 reconnect, A1-A3 AP+STA on one radio); this is the
OS side. Nothing here touches the driver.

- **Configuration** is the network list, one block, at most one per list:
  `station=<band>` with `enabled=0|1`, `ssid=`, `security=psk2|sae` (6 GHz:
  sae), `passphrase=` (stored like the AP passphrases: the 0600 list and a
  0600 generated config, never echoed in an error), optional `bssid=`. No
  ssid = the station runs with no network and only scans (the web UI scans
  through it). `gt-be98-wifi-gen` renders `sta-<dev>.conf` (wpa_supplicant:
  ssid and SAE password in hex form, so no quoting rule applies; a WPA2
  passphrase quoted, refused only when it holds both `"` and `#`, which
  wpa_supplicant's comment rule would cut) and a plan line `station`.
- **Which netdev**: the station is the radio netdev `bcawlN` itself
  (bsscfg 0: the firmware's AP+STA model, apsta/mbss); the radio's networks
  move to virtual interfaces `bcawlN-k` (k >= 1: slot 0 and the radio
  address are the station's), so a station radio carries one network less
  (`-C` - 1). A network remembered at slot 0 is reallocated (warning); it is
  promoted back to the anchor when the station goes.
- **Order** (the one measured on silicon, stawds A1; the AP-start arming
  window with a live station is the path that trapped the firmware,
  STA-WDS §24): `gt-be98-wifi` (1) has hostapd release the radio netdev,
  (2) creates the first AP's virtual interface (`iw ... type __ap`),
  (3) starts the station (`gt-be98-wifi-sta up`: wpa_supplicant, waits up to
  `STA_WAIT` s for the association), (4) starts the APs. A virtual
  interface that appears under a running station makes the station
  reconnect, so (2) always precedes (3). Removing a station reverses it:
  APs off the virtual interfaces, station down, APs on the radio netdev.
- **Channel**: one per radio; the driver refuses an AP on another channel
  than an associated station (`-EBUSY`). The generator's `-U band=MHz`
  (from the associated station) puts the radio's APs on the uplink's
  channel, the width lowered to the widest block that holds it. When the
  uplink moves the radio later (the firmware follows the uplink; hostapd is
  not told), the monitor daemon (`gt-be98-wifi-sta monitor`, started and
  stopped with `gt-be98-wifi`, like the schedule daemon) sees the station's
  frequency differ from its APs' and reloads the service (at most once per
  `STA_FOLLOW_MIN` s per radio). It also restarts a dead wpa_supplicant or
  DHCP client. A DFS uplink channel makes hostapd run its CAC on that
  channel first (the APs are silent for it) [not measured].
- **Address**: DHCP on the station netdev, dhcpcd (the OS's only client)
  in a private mount namespace (`unshare -m`, its own `/var/run/dhcpcd`):
  the OS's dhcpcd manager refuses `bcawl*` by design and would take over a
  second instance through its control socket. `nogateway`: the script
  installs the box's default route through the uplink at metric
  `STA_METRIC` (3000, below every management route: the USB lifeline and
  rnr0 keep the box's default; `STA_DEFAULT_ROUTE=0` for none).
- **Routed, never bridged**: a 3-address station cannot be bridged (cfg80211
  refuses it; 4-address/WDS is parked, STA-WDS §31), so clients reach the
  uplink only through a ROUTED network: `routed=A.B.C.1/P` instead of
  `vlan=` (a private subnet, the box its first host). Its bridge brwifiN
  holds only its BSSes; `gt-be98-wifi-sta route` puts the address on it,
  runs a dnsmasq (DHCP from the second host, DNS forwarded to the uplink's
  servers, bound to the routed bridges only), policy-routes it
  (`ip rule iif brwifiN table STA_TABLE` = 181: default via the uplink's
  gateway, `unreachable` without a lease, never another default) and
  loads `table ip gt_be98_sta` (forward only routed network <-> station,
  replies back; masquerade out of the station). VLAN networks on the same
  radios stay bridged to their trunk VLANs (they do not reach the uplink).
- **Repeater (bridged, layer 2; lane repeater 2026-11-03)**: `repeater=4addr`
  or `repeater=multiap` on the station block and `repeated=1` on ONE network
  (instead of `vlan=`/`routed=`). The station runs in nl80211 4-address
  mode, set before wpa_supplicant joins (the driver writes the firmware's
  `dwds`/`map` rows in the join's core-down window, STA-WDS §29-30;
  `multiap` also writes `multi_ap_backhaul_sta=1`, so the join needs a
  Multi-AP backhaul BSS), and `gt-be98-wifi-sta` makes it a port of the
  repeated network's bridge brwifiN: its clients are on the uplink's LAN
  (its DHCP, its router). The station then has no DHCP client and no
  default route (a bridge port is no IP host), and `routed=` is refused
  beside it. The repeated bridge holds no VLAN and no trunk port (the
  generator, the service and netguard each refuse one: with a Wi-Fi uplink
  in it, a trunk VLAN would loop the wired LAN into the uplink's segment).
  The uplink must accept 4-address frames from a station (hostapd
  `wds_sta=1`, a Multi-AP backhaul BSS, a Broadcom DWDS AP): the lab's
  MT7925 cannot (its driver clears `WIPHY_FLAG_4ADDR_AP`/`_STATION`), so
  this mode is box-verified only once a capable uplink is on the bench
  (open-wifi `docs/REPEATER-2026-11-03.md`).
- **netguard / router**: `gt-be98-netguard` detaches a station netdev
  (`/run/gt-be98-wifi/stations`) from any bridge, except a repeater
  (`/run/gt-be98-wifi/repeaters`, `<dev> <bridge>`) in its own repeated
  bridge, never isolated; `gt-be98-router` refuses
  one as a LAN and leaves forwarding on while routed networks run.
- Tests (offline, dev-build): `test/gt-be98-wifi-gen-test.sh` (station
  and routed rendering and refusals, every awk; with `WPA_CONFCHECK=` every
  station config parsed by wpa_supplicant's own parser,
  `test/build-wpa-confcheck.sh`; with the hostapd confcheck every hostapd
  config), `test/gt-be98-wifi-service-test.sh` (the order above against a
  fake hostapd), `test/gt-be98-wifi-sta-test.sh` (the helper against fake
  tools). Box arms: `os-sta-arms.sh` (lab, not in git).

### WAN modes (gt-be98-wan)

Design (lane os-wan, 2026-11-03). Default: DHCP on untagged `rnr0` by
dhcpcd, exactly as before; every other mode is opt-in.

- **Configuration**: `/etc/gt-be98-wan/wan.conf` (0600, KEY=VALUE, parsed
  never sourced; no file = the default; saved to `/jffs` with the other
  network state). `WAN_PROTO=dhcp|static|pppoe`, `WAN_PORT=rnr0..rnr3`,
  `WAN_VLAN=1..4094` (any proto: an 802.1Q sub-interface of the port, e.g.
  an ISP's VLAN 6 or 835), static `WAN_ADDR=a.b.c.d/p WAN_GW= WAN_DNS=`,
  `PPPOE_USER PPPOE_PASS PPPOE_SERVICE PPPOE_AC PPPOE_MTU` (1492),
  `WAN_MTU` (dhcp/static), `WAN_METRIC`, `WAN_IPV6=1` with
  `WAN_PD_LANS="brwifi1 br-lan"` and `WAN_PD_LEN` (hint). `gt-be98-wan
  check FILE` validates (a VID that is a Wi-Fi trunk VLAN on the same port,
  a gateway outside the subnet, PD LANs that are not routed LANs, ... are
  refused) and never prints the password. The web UI's WAN card writes a
  candidate and hands it to `gt-be98-wan try`.
- **Daemons**: dhcpcd stays the only DHCP/static client. `init.d/dhcpcd`
  starts it on the config `gt-be98-wan dhcpcd-conf` renders into
  `/run/gt-be98-wan/` (a byte copy of `/etc/dhcpcd.conf` in the default
  mode, the image's own file on any error): static = a dhcpcd `static`
  profile, DHCPv6 = `ipv6rs` + `ia_na 1` + `ia_pd 2[/::/len] <lan>/<n>/64`
  on the WAN netdev, the delegated LANs listed with `noipv4 noipv6rs
  nodhcp6`. PPPoE = pppd (Buildroot `pppd` 2.5.3) with its `pppoe.so`
  plugin over the kernel's PPPoE (`CONFIG_PPP=m`, `CONFIG_PPPOE=m`; the
  other pppd plugins are removed from the image; rp-pppoe is only a
  server's need): netdev `pppoe-wan`, `persist`, LCP echo 20 s x 3, the
  options file 0600 in `/run/gt-be98-wan` (password inside), peer DNS
  merged into `/etc/resolv.conf` through dhcpcd's per-interface fragment
  directory (`/run/dhcpcd/resolv.conf/pppoe-wan.ppp`). Router
  advertisements on the delegated LANs: a dnsmasq with `port=0` and
  `ra-only` constructor ranges (no DHCP, no DNS socket), RDNSS = the WAN's
  IPv6 servers.
- **Routes**: the WAN's default route metric: dhcpcd's own (1000 +
  ifindex) for dhcp/static, 4000 for PPPoE (`WAN_METRIC` overrides): on
  the bench the management default via untagged `rnr0` keeps winning, so a
  WAN on a VLAN or PPPoE never takes the box's own traffic. Routed LANs
  reach the WAN by policy routing: IPv4 through gt-be98-router
  (`ROUTER_WAN="wan"` follows the WAN netdev: `rnr0`, `rnr0.<vid>` or
  `pppoe-wan`; a point-to-point default goes into table 180 as `default
  dev pppoe-wan`; pppd's ip-up/ip-down and dhcpcd's hooks reroute it),
  IPv6 through table 182 (`ip -6 rule iif <lan>`, default = the WAN's own
  v6 default, `unreachable` without one; dhcpcd hook `07-gt-be98-wan`).
  `net.ipv6.conf.all.forwarding=1` only while prefixes are delegated
  (dhcpcd owns RA processing and sets `accept_ra=0`, so the box's own IPv6
  routes do not depend on it).
- **Firewall / NAT**: `table inet gt_be98_wan`: TCP MSS clamped to the
  route MTU both ways on a PPPoE or reduced-MTU WAN (`tcp option maxseg
  size set rt mtu`: nft_exthdr + nft_rt, built into nf_tables); from the
  WAN into the delegated LANs only replies and ICMPv6; the box's own
  input from a WAN netdev other than the bare port (a VLAN or `pppoe-wan`):
  replies, ICMP, DHCP client replies only. The bare port gets no input
  filter (on the bench it is the management path). Masquerade stays where
  it was: gt-be98-router's `router.nft` (any non-Wi-Fi output) and the web
  UI's `table ip webui`, whose WAN interface follows the OS's WAN netdev
  when it is a VLAN or PPPoE of `WAN_IF`.
- **MTU**: PPPoE MTU/MRU 1492 (8 bytes of PPPoE + PPP header in a 1500
  frame), MSS clamped as above. `WAN_MTU` (1280..1500) for a dhcp/static
  WAN that needs less. A VLAN WAN keeps 1500 (the tag is not counted).
- **Management safety**: `gt-be98-wan try SECONDS FILE` (30..3600) applies a
  TRIAL config that exists only in `/run/gt-be98-wan` (never saved, so any
  reboot during a trial comes back on the saved config) and reverts by
  itself after SECONDS unless `gt-be98-wan confirm` (then it is saved);
  `revert` drops it at once. Two independent enforcers of the deadline:
  the service's watcher (`gt-be98-wan watch`, started by
  `init.d/gt-be98-wan`, so no caller is in its ancestry) and a one-shot
  timer in its own session; the deadline is the trial's token, so neither
  can revert a later trial. Applying a WAN change rebinds in dhcpcd only
  the interfaces whose block changed: a VLAN or PPPoE WAN never rebinds
  untagged `rnr0` (a rebind restarts the interface's DHCP). A VLAN WAN never touches untagged `rnr0`, a
  PPPoE WAN on `rnr0` leaves its DHCP lease alone, only a static WAN on
  the bare port replaces the management lease (bench: never; product:
  through the trial).
- **Runner offload**: the flow cache learns routed flows only between
  Runner ports or bridges over them (open-ethernet `flowcache.c`
  `fc_dev_candidate`, `fc_l3_resolve_devs` "ingress is not a Runner
  port"), and the flowtable glue refuses actions it does not parse
  (`flow_offload.c`: no `FLOW_ACTION_PPPOE_PUSH`). So **PPPoE and VLAN-WAN
  routed traffic is forwarded by the CPU**; a DHCP/static WAN on the bare
  port keeps the hardware offload. PPPoE offload needs Runner work (the
  parser already knows PPP_IP, `parser.c`; the cmdlist would push/pop the
  8-byte PPPoE header).
- Tests (offline): `test/gt-be98-wan-test.sh` (dash, bash; fake ip, nft,
  pppd, dhcpcd, sysctl, start-stop-daemon). Box arms: `wan-arms.sh` (lab,
  not in git). Not measured on silicon yet.

### Web UI

The webui-go delivery (`WEBUI_DIR`) is installed with `/etc/webui/platform.conf`
set to `WAN_IF=rnr0` (the LAN port: a plain DHCP client, never bridged),
`MGMT_IF="eth0 rnr0"` (the UI on the USB lifeline and on the LAN port), `DNSMASQ_DNS=0`, and no
`ALLOW_MULTI_PORT_BRIDGE`. The service is **enabled only when a password is
provisioned** in the local configuration (`WEBUI_PASSWORD`, or
`WEBUI_PASSWORD_HASH`): the build writes `/etc/webui/auth.conf` (`SALT=`,
`HASH=sha256(SALT || password)`, the webui's own format, imported into its
`webui.db` on the first start). Without one the service stays disabled, and
`gt-be98-webui-guard` (required by `webui`) refuses a manual start of an
unprovisioned webui, so it never serves an open first-run page on the LAN.
The guard does start a webui with the first-login setup token (`webui
-features` prints `setup-token`): unprovisioned, it accepts only
`set_password` with the root-only token in `/run/webui/setup-token`. A
release image (`RELEASE=1`) enables the web UI that way, without a password
(`docs/RELEASE-BUILD.md`).
With `WAN_IF` (rnr0) also listed in `MGMT_IF`, the webui skips its WAN block
on rnr0 (`WAN_BLOCK_PORTS` is not applied there), so the UI is reachable from
the LAN rnr0 sits on: intended for this dev box (password-protected; needs a
webui whose `MGMT_IF` takes a list, webui-go mainline-os 6554144 or later).
`gt-be98-netguard` keeps `rnr*`/`eth*` out of any bridge whatever the web UI
does. The package version is a digest of the delivery, so a new webui build
is picked up by a plain `build.sh`.

`/etc/webui` (including `webui.db`) is in the RAM overlay: changes made in
the UI are lost at reboot. Persistence will come with the USB stick
(`GTBE98-DATA`, `PERSISTENCE.md` levels 1/4: `/data/etc-overlay/` is already
copied over `/etc` at boot, so a `webui/` saved there is restored; writing UI
changes back to the stick automatically is part of that plan, not done yet).

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
- `oops=panic panic=5` stay on the forced command line (an oops reboots into
  stock 5 s later). To keep the box up after an oops while debugging:
  `sysctl -w kernel.panic_on_oops=0`.
- Crash capture: see "Crash logs (netconsole)" below.
- `CONFIG_MODULE_FORCE_UNLOAD=y`: `rmmod -f` exists for a wedged module.

### Crash logs (netconsole)

A panic reboots the box into the committed stock slot, the UART is not
reachable, and **no RAM-based log survives**: the loader's DDR init re-keys
the DDR scrambler from the hardware RNG on every reset (warm, watchdog or
panic) and leaves no region unscrambled (open-ethernet
`docs/mainline-noUART-bringup.md`, section 2a). So pstore/ramoops is
compiled but has no region, and none is reserved in the DT: there is no
provably safe one. The kernel log has to leave the box before the reset:

- `CONFIG_NETCONSOLE=m` (+ `CONFIG_NETCONSOLE_DYNAMIC`, configfs). The
  `gt-be98-netconsole` service (default runlevel, after `gt-be98-drivers` and
  `dhcpcd`) loads it only if `/etc/conf.d/gt-be98-netconsole` sets
  `NETCONSOLE` (default: empty, disabled). The value is the module's
  `netconsole=` parameter, e.g. `NETCONSOLE="@/rnr0,6666@<lab-host>/"`
  (`<lab-host>` = an IPv4 address; add the host's MAC after the last `/` to
  send unicast instead of broadcast). Then `rc-service gt-be98-netconsole
  restart`; `gt-be98-save` / autosave keep the file in `/jffs`. A build-time
  default: `NETCONSOLE=` in the local configuration file.
- On the lab host: `socat -u udp-recv:6666 - | tee -a gt-be98-console.log`.
- The console loglevel stays 4 (warnings are not sent). An oops, a panic and
  the soft-lockup report are always sent: the kernel raises the level for
  them. `NETCONSOLE_LOGLEVEL=` in the conf.d file raises it for everything,
  UART included (each line then costs ~87 us/char on the UART).
- `panic=5` (and `CONFIG_PANIC_TIMEOUT=5`): 5 s between the panic report and
  the reset, so the last frames are on the wire. `oops=panic` and
  `softlockup_panic=1` are unchanged.
- Two kernel patches make netconsole transmit at all (open-ethernet
  `series.postcode`, root cause measured on the box 2026-10-22). The be98pc
  post-code earlycon is a BOOT console kept by `keep_bootcon`, and while any
  boot console is registered 7.2 printk starts no nbcon printer thread:
  netconsole (an nbcon console with an unsafe `write_atomic()`) then queued
  every line until something took the console lock. 0510 hands be98pc over
  to a regular console at `late_initcall` (post-codes keep working). ⚠
  `keep_bootcon` must STAY on the command line: without it the UART console
  unregisters the boot console before the handover. 0511 flushes unsafe
  nbcon consoles before the panic reboot; v7.2 only does it with `panic=0`,
  so with `panic=5` no panic frame was ever sent.
- The Runner driver takes its TX lock with a trylock under netpoll and
  returns busy on contention, so a panic on a CPU that held the lock cannot
  deadlock the netconsole send.
- ⚠ Not yet seen on the wire from a real panic on this image: check once
  with `echo c > /proc/sysrq-trigger` (it reboots into stock) before
  relying on it.
- RCU stall then watchdog reset during `rmmod bca_pcie_ipc` (2026-10-22..26,
  three times; netconsole showed CPU 0 frozen in `pr/ttyAMA0`): the printer
  was the interrupted task, not the cause. A Wi-Fi MSI posted just before
  the driver freed its vectors stayed latched in the root complex (only the
  mapped interrupt's ack clears it), so the level PCIe interrupt, routed to
  CPU 0, re-entered for ever. open-ethernet 0906 acknowledges such an MSI
  and logs `MSI <n> has no interrupt mapped: cleared`. The UART printer
  only widened the window: it keeps interrupts off for a whole record.

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

### NAND and /jffs persistence (default `NAND=rw-jffs`)

Since 2026-10-08 (G7 and G8 passed on the box, NAND-PHASE2.md) the dev OS
mounts the stock `/jffs` read-write and keeps its state in
`/jffs/mainline-os/`: `state.tgz` (the web UI settings, SSH host keys,
authorized_keys, dhcpcd/chrony state) is applied at boot, saved at every
clean shutdown/reboot and by `gt-be98-autosave` within ~10 minutes of a
change (web UI settings, SSH keys); `gt-be98-save --local` saves at once.
Writes are possible ONLY through the UBI write fence on `jffs2`; four
independent layers stay in place (DT: only `image` writable, never `loader`;
`brcmnand.allow_write`; the MTD write gate; the UBI fence). Any failed
pre-check leaves the box read-only (phase 1) with "PERSISTENCE OFF" in the
log at crit level, `/run/gt-be98-jffs.status` and `/etc/motd`. At every
boot the static volumes' sha256 (bootfs1/2, metadata1/2) are compared with
the previous boot (`/jffs/mainline-os/nandcheck.last`); a change of bootfs1
with a new image build id is logged as a flash, anything else at crit level.
`gt-be98-status` shows the state. `NAND=ro` (phase 1, nothing writable,
NAND.md) and `NAND=off` remain available.

## Safety rules this OS keeps

- Flash writes only to the stock `/jffs` (UBI volume jffs2) and free PEBs,
  through the UBI write fence (NAND-PHASE2.md); `loader` and every other
  volume (both slots, metadata, data, defaults) are never written; with
  `NAND=ro`, nothing at all (NAND.md).
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

# GT-BE98 mainline OS - test plan (orchestrator, on the box)

The bootfs FIT is flashed and trial-booted exactly like the mainline
diagnostic images: UBI volume 3 (bootfs of slot 1), one-shot boot with
`bcm_bootstate 3; reboot` from the stock slot 2, which stays committed and is
the automatic fallback (watchdog). Nothing on slot 2 changes. The OS itself
(`rootfs.squashfs`) is not in the FIT: `/init` takes it from a USB stick
labelled `GTBE98-ROOT` or fetches it over HTTP (`ROOTFS_URL`).

Placeholders: `<box-usb>` = the address the USB lifeline gets from the lab
DHCP server, `<box-lan>` = the address `rnr0` gets on the LAN, `<lan-host>` =
a LAN machine with iperf3, `<http>` = the lab HTTP server. Keys: the image
accepts the public keys in the build host's local configuration.

## T0. Build with the URL, serve the rootfs

```sh
# build host: ROOTFS_URL in ~/.config/gt-be98-os/local.conf, e.g.
#   ROOTFS_URL=http://<http>:<port>/gt-be98/rootfs.squashfs
# (or http://@DHCP_SERVER@:<port>/... to use the DHCP server's address)
cd ~/os-build/gt-be98-buildroot && rtk sh board/gt-be98-mainline/build.sh   # reruns post-image
cat ~/os-build/out-mainline/images/ml-bootfs.info      # sizes, sha256, the URL baked in
# serve BOTH files from the same directory on <http>:
#   rootfs.squashfs  rootfs.squashfs.sha256
curl -sI <ROOTFS_URL> | head -1; curl -s <ROOTFS_URL>.sha256       # from the lab LAN
```

The URL is baked into the FIT (`/etc/ml-defaults` of the initramfs):
changing it means rebuilding (post-image only, ~1 min) and reflashing. A
new rootfs alone needs only a new `rootfs.squashfs` + `.sha256` on the
server, no reflash.

Alternative without HTTP: a USB stick (second USB port) with a partition
labelled `GTBE98-ROOT` holding `rootfs.squashfs` (vfat or ext4):
`mkfs.vfat -n GTBE98-ROOT /dev/sdX1; cp rootfs.squashfs /mnt/`.

On the box (stock), before flashing:

```sh
bcm_bootstate | grep -iE 'commit|valid|seq|booted'   # committed 2, valid 1,2, booted 2
grep -o 'ubi.block=0,[0-9]' /proc/cmdline             # ubi.block=0,6
/bin/busybox sh /jffs/scripts/postcode-read.sh        # log + clear the post-code byte
ubinfo -d 0 | grep -E 'available logical|eraseblock size'
```

## T1. Flash vol 3 (slot 1 bootfs) - the procedure used on 2026-10-08

Done once (operator decision): slot 1's rootfs volume (vol 4, the open-enet
4.19 rootfs, unused by this OS) was backed up to the build host
(`~/be98/os-inputs/oe-tool/backup/slot1-rootfs1-vol4-20261008.bin`) and replaced by
`rootfs1-stub.squashfs` (4 KiB, sha256 in `ml-bootfs.info`) in a 1 MiB
volume, which frees the space; vol 3 was recreated at 48 MiB. U-Boot only
checks the squashfs magic of vol 4 before booting slot 1.

```sh
# on the box, slot 2 (stock) booted
grep -q 'ubi.block=0,6' /proc/cmdline || exit 1
# once: vol 4 -> stub (back up first: dd if=/dev/ubi0_4 of=... and copy it off)
ubirmvol /dev/ubi0 -n 4
ubimkvol /dev/ubi0 -n 4 -N rootfs1 -s 1MiB -t dynamic
ubiupdatevol /dev/ubi0_4 /tmp/rootfs1-stub.squashfs
# every new image: vol 3 at 48 MiB, then the FIT
ubirmvol /dev/ubi0 -n 3
ubimkvol /dev/ubi0 -n 3 -N bootfs1 -s 48MiB -t static
ubiupdatevol /dev/ubi0_3 /tmp/ml-bootfs.itb
S=$(stat -c %s /tmp/ml-bootfs.itb)
dd if=/dev/ubi0_3 bs=$S count=1 2>/dev/null | sha256sum   # == ml-bootfs.info
bcm_bootstate 3; reboot
```

Results on the box (2026-10-08): the ~16 MB netroot FIT boots (ssh on the
lifeline at ~50 s, post-code fa); the 46 MB FIT with the rootfs inside
(IMAGE=initrd) never reached the kernel (post-code byte untouched, back to
stock after ~9-10 min) although the same procedure wrote and verified it.
Restoring vol 4: `ubirmvol` it, `ubimkvol` it at the backup's size,
`ubiupdatevol` the backup.

### T1b. Size probe (optional, one boot) - NOT TESTED YET

Flash `ml-bootfs-pad30.itb` instead (same kernel/DT, padded to 30 MiB with an
unreferenced image) and trial-boot it. Any post-code ≥ c0 (or a lifeline
address) means a 30 MiB bootfs loads; an untouched byte means the boot chain
refuses it (as the 46 MB one). With `ROOTFS_URL` set it boots the full OS
like the normal image.

## T2. Trial boot

```sh
bcm_bootstate 3; reboot
```

Expected timeline (from the kernel start):

| Step | Expected | Post-code if it stops there |
|---|---|---|
| kernel, `/init` | < 3 s | below c0 (kernel), c0..c5 |
| USB NIC, address | < 45 s | c6, c7 (e8: no address -> reset by U-Boot's watchdog) |
| `/init` petting | | c9 |
| USB root / HTTP fetch (29 MB) | a few s | d7/d8, d9/da (e5 fetch failed, e6 bad sha256 -> rescue: telnet `<box-usb>`) |
| rootfs mounted, OpenRC | | f1, f2, f3 |
| watchdog petting (OS) | | f4 |
| dhcpcd, sshd | | f5, f6 |
| Runner loaded | | f7 (e7 = insmod failed) |
| default runlevel | | fa |
| health confirmed | | fb |

A box that never becomes reachable resets itself back to stock (the `/init`
window is bounded at 300 s; the OS needs health after 180 s + 300 s grace).

## T3. ssh over the USB lifeline

```sh
ssh root@<box-usb>                  # key only; no password prompt must appear
gt-be98-status                      # health: healthy, both addresses, modules
cat /etc/gt-be98-release; uname -a  # 7.2.9, versions
rc-status                           # boot + default services started
printf '0x%08x\n' $(devmem 0xff802628 32)    # top byte fb (or fa just after boot)
ssh -o PasswordAuthentication=yes -o PubkeyAuthentication=no root@<box-usb>   # must be refused
```

PASS: login with the key, `gt-be98-status` says healthy, no service crashed
(`rc-status --crashed` empty), `dmesg | grep -iE 'oops|bug|warn'` clean.

## T4. ssh over rnr0 (LAN)

```sh
ip -4 addr show rnr0                # DHCP address on the LAN
ssh root@<box-lan>                  # from a LAN machine
ip route                            # default routes via both, rnr0/USB metrics differ
```

## T5. Drivers: unload / reload

```sh
rc-service gt-be98-drivers restart      # rmmod + modprobe bcm4916-runner flow_offload=1
dmesg | tail -30
ip link show rnr0; sleep 15; ip -4 addr show rnr0   # dhcpcd re-acquires the address
# a few rounds, the box must stay healthy
for i in 1 2 3; do rc-service gt-be98-drivers restart; sleep 20; ping -c 3 <lan-host>; done
# by hand, with a copied module
scp bcm4916-runner.ko root@<box-usb>:/tmp/ && ssh root@<box-usb> \
  'rmmod bcm4916_runner; insmod /tmp/bcm4916-runner.ko flow_offload=1'
```

Wi-Fi driver (optional): `modprobe bca_pcie_ipc; dmesg | tail; iw dev;
rmmod bca_pcie_ipc` (four radios enumerate: `lspci`).

## T6. Ping / iperf

```sh
ping -c 100 -i 0.2 <lan-host>                 # 0 % loss
ping -f -c 20000 -s 1400 <lan-host>           # flood: 0 % loss expected
iperf3 -s &                                   # on the box
# on <lan-host>:
iperf3 -c <box-lan> -t 30 ; iperf3 -c <box-lan> -t 30 -R ; iperf3 -c <box-lan> -t 30 -P 4
cat /sys/kernel/debug/bcm4916-runner/ringstat   # no ring stall after the runs
```

Routed / NAT-C offload tests are as on the diagnostic image (enable
forwarding with `sysctl -w net.ipv4.ip_forward=1`, nftables flowtable with
`flags offload`); `conntrack -L` shows `[OFFLOAD]` entries.

## T7. Wi-Fi AP (optional, service disabled by default)

```sh
cp /etc/hostapd/hostapd-wl24.conf.example /etc/hostapd/hostapd-wl24.conf
vi /etc/hostapd/hostapd-wl24.conf        # ssid, passphrase (test values)
echo 'HOSTAPD_CONFS=/etc/hostapd/hostapd-wl24.conf' >> /etc/conf.d/gt-be98-wifi
rc-service gt-be98-wifi start            # iw reg reload, bca_pcie_ipc, hostapd
iw reg get; iw dev; hostapd_cli -p /run/hostapd status   # state=ENABLED
rc-service gt-be98-wifi stop             # hostapd stops, module unloads
```

- `wmm_enabled=1` is required: without it the firmware's beacon RSN
  capabilities (0x000c) do not match hostapd's 3/4 RSN IE (0x0000) and
  clients drop with reason 17.
- `country_code`: the image ships wireless-regdb (`/lib/firmware/regulatory.db`
  + `.p7s`) in the rootfs and in the kernel's initramfs, where the built-in
  cfg80211 loads it at boot (before 2026-10-26 that load failed, every hint
  went to CRDA and timed out silently, and `iw reg set` left `00`). No CRDA
  (`CFG80211_CRDA_SUPPORT` off). Check: `iw reg set FR; iw reg get` shows
  `country FR` in the global domain. The service still runs `iw reg reload`
  before hostapd and writes `country_code` only when it succeeds.

Result 2026-10-08 (2.4 GHz, WPA2): AP up, a client got 18 Mbit/s up,
11 Mbit/s down.

### T7b. Wi-Fi networks, one hostapd for all radios (multi-SSID)

Offline first (build host, no box): `sh package/gt-be98-os/test/gt-be98-wifi-gen-test.sh
<hostapd-confcheck>` (the generator; hostapd's own parser and checks from
`test/build-hostapd-confcheck.sh`) and `sh package/gt-be98-os/test/gt-be98-wifi-service-test.sh`
(the service's ADD/REMOVE decisions against a fake hostapd): both `ALL OK`.

On the box (trunk VLANs 10/20/30 reachable from a lab switch port):

```sh
cp /etc/hostapd/networks.conf.example /etc/hostapd/networks.conf   # passphrases
echo 'WIFI_NETWORKS=/etc/hostapd/networks.conf' >> /etc/conf.d/gt-be98-wifi
rc-service gt-be98-wifi start
pidof hostapd                                       # ONE pid
hostapd_cli -p /run -i hostapd-global raw INTERFACES
#   bcawl3 bcawl3-1 bcawl3-2 bcawl0 bcawl0-1 bcawl1 bcawl1-1 bcawl2
cat /run/gt-be98-wifi/gen/plan /etc/hostapd/wifi-slots   # slots, BSSIDs, bridges
for i in bcawl3 bcawl3-1 bcawl3-2; do hostapd_cli -p /run/hostapd -i $i status | grep -E '^(state|bssid|ssid)'; done
ip -br link show master brwifi30                    # guest BSSes + rnr0.30
```

Pass: one process; every BSS `state=ENABLED` with the `bssid` of the plan
(and `ip link` shows it as the netdev MAC); each network's BSSes in its
`brwifi<id>`; a client on each SSID gets an address from its VLAN.
Per-BSS changes (the counters, not the verdict, are what to read:
`grep -E 'REMOVE|ADD|Remove|Add' /var/log/hostapd.log` and the client links):

1. change iot's passphrase, `rc-service gt-be98-wifi reload`: only
   `bcawl3-2` is removed and added; a client on home (`bcawl3-1`) and guest
   (`bcawl3`) stays associated (no deauth, ping without a gap > 1 s).
2. delete network 10 (home): `bcawl3-1`, `bcawl0-1`, `bcawl1-1` removed,
   nothing else; iot keeps `bcawl3-2` and its BSSID.
3. add a network on 5gl: one `ADD bss_config`; the other radios untouched.
4. change guest (the anchor of every radio): each radio restarts once
   (expected: hostapd removes a radio with its first BSS, and the driver's
   anchor start re-runs the radio prologue).
Refute: any other radio's or BSS's client dropping in 1-3; a BSS whose
BSSID differs from the plan; two BSSes with one BSSID. Driver limits that
can make 1-3 fail on the box today (not the OS): MULTI-SSID-TARGET G4/G12
(a removed BSS's peers/rings not released), G5 (anchor `WLC_DOWN`), G13/G15.

### T7c. WPA2/WPA3-Enterprise (802.1X, external RADIUS)

Offline: section 9 of `gt-be98-wifi-gen-test.sh` (with `hostapd-confcheck`
built from the image's hostapd `.config`, so the EAP/RADIUS options are the
image's; against the EAP-less hostapd of earlier images every Enterprise
config fails to parse). On the box: `grep -c auth_server_addr
/usr/sbin/hostapd` is non-zero (0 on an EAP-less build: no RADIUS client,
the key is unknown).

RADIUS server: any lab host reachable from the box's management address,
e.g. hostapd's integrated RADIUS server (a full hostapd build: `eap_server=1`,
`radius_server_clients=` with the box's address and the secret,
`radius_server_auth_port=1812`, `eap_user_file=` with a PEAP/MSCHAPv2 user,
`ca_cert=`/`server_cert=`/`private_key=`) or FreeRADIUS (`clients.conf`,
`users`). One network on the box:

```
network=40
ssid=corp
security=wpa2-wpa3-eap
radius_server=<lab host>
radius_secret=<secret>
bands=2g 5gl 6g
vlan=40
```

`rc-service gt-be98-wifi reload`; on the 6 GHz BSS `hostapd_cli -p
/run/hostapd -i bcawl2-<k> get_config` shows `key_mgmt=WPA-EAP-SHA256`.
Client (`wpa_supplicant -c` with `key_mgmt=WPA-EAP WPA-EAP-SHA256`,
`ieee80211w=1`, `eap=PEAP`, `identity=`, `password=`,
`phase2="auth=MSCHAPV2"`, `ca_cert=`), once per band:
Pass: `CTRL-EVENT-EAP-SUCCESS` then `CTRL-EVENT-CONNECTED`; `wpa_cli status`
shows `key_mgmt=WPA2-EAP-SHA256` (2.4/5 GHz: SHA256 is preferred, `pmf=1`)
or the same with `pmf=2` on 6 GHz; the RADIUS server logged an
Access-Accept for the box's address; DHCP from VLAN 40; ping both ways.
Repeat with `security=wpa2-eap` (client `key_mgmt=WPA-EAP`) on 2.4 GHz.
Refute: an Access-Accept but no `CONNECTED` (4-way: `reason=17` is an RSN
IE mismatch between the firmware's beacon and hostapd's message 3 - read
the driver's `AP RSN-CAPS` line in the kernel log), no Access-Request at the
server (RADIUS path/secret: hostapd log `RADIUS`), or a wrong secret
accepted. Then change `radius_secret` on the box only and reload: the
server must log a bad authenticator and the client must fail.

## T8. Watchdog

1. **Healthy box stays up**: leave it 20 min; uptime keeps growing,
   `logread`-style check `grep wdtd /var/log/messages` shows only the start.
2. **Manual stop resets**: `rc-service gt-be98-watchdog stop` -> the box
   resets within ~30 s and comes back on stock. Post-code read on stock:
   **fc**.
3. **Unhealthy box resets**: `rc-service sshd stop; ip link set rnr0 down;
   ip link set <usb if> down` (from a session that does not need them, e.g.
   `nohup sh -c '...' &`) -> after 300 s of failed checks the box resets.
   Post-code on stock: **fd**.
4. **Reboot**: `reboot` -> stock comes back (one-shot trial), post-code **fe**.

## T9. Rescue path (optional, separate image)

Build with `RESCUE=1` in the local configuration (`/init` skips the rootfs):
expected post-codes e4, then c6, c7,
telnet on `<box-usb>:23` (root shell, no password), reset at the petting
deadline (ca) unless extended with `echo 1 > /tmp/extend`.

## T10. Web UI (optional, service disabled by default)

```sh
ls -l /usr/sbin/webui /etc/webui/platform.conf      # installed from the webui-go delivery
rc-service webui start; rc-service webui status; curl -sI http://127.0.0.1/ | head -1
bridge link                                         # rnr0 must NOT be a bridge member
rc-service webui stop
```

## Post-code summary (read on stock after the box returned)

| Final code | Meaning |
|---|---|
| fe | clean reboot from the OS |
| fd | health check failed for 300 s (unreachable) |
| fc | `gt-be98-watchdog` stopped by hand |
| fb / fa | box was healthy / fully booted when it was reset (power cut, kernel hang or oops -> panic) |
| f7 / e7 / f6 / f5 / f4 | boot stopped after Runner load / Runner failed / sshd / dhcpcd / petting start |
| f1..f3, d7..da | rootfs source / mount steps |
| e0..e6, e8, c8, ca, ee | rescue path (see `README.md`) |
| c0..c9 or lower | kernel or early `/init` (c6/c7: lifeline; c9: `/init` petting) |
| unchanged (preset value) | the kernel never ran: the boot chain did not start the bootfs |

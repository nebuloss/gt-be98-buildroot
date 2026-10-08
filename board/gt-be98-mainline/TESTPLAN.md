# GT-BE98 mainline OS - test plan (orchestrator, on the box)

The image is flashed and trial-booted exactly like the mainline diagnostic
images: UBI volume 3 (bootfs of slot 1), one-shot boot with
`bcm_bootstate 3; reboot` from the stock slot 2, which stays committed and is
the automatic fallback (watchdog). Nothing on slot 2 changes.

Placeholders: `<box-usb>` = the address the USB lifeline gets from the lab
DHCP server, `<box-lan>` = the address `rnr0` gets on the LAN, `<lan-host>` =
a LAN machine with iperf3. Keys: the image accepts the public keys listed in
the build host's local configuration (`SSH_AUTHORIZED_KEYS`).

## T0. Before flashing (stock, slot 2)

```sh
# on the build host
sha256sum ~/os-build/out-mainline/images/ml-bootfs.itb    # == ml-bootfs.info
cat ~/os-build/out-mainline/images/ml-bootfs.info          # sizes, margin
# on the box (stock)
bcm_bootstate | grep -iE 'commit|valid|seq|booted'   # committed 2, valid 1,2, booted 2
grep -o 'ubi.block=0,[0-9]' /proc/cmdline             # ubi.block=0,6
/bin/busybox sh /jffs/scripts/postcode-read.sh        # log + clear the post-code byte
ubinfo -d 0 | grep -E 'available logical|eraseblock size'
ubinfo -d 0 -n 3 | grep -E 'Size|Name|Type'
```

The new FIT is ~3x the stock bootfs (`ml-bootfs.info`). Space check, on the
box:

```sh
L=$(ubinfo -d 0 | sed -n 's/.*logical eraseblock size: *\([0-9]*\).*/\1/p')   # LEB bytes
A=$(ubinfo -d 0 | sed -n 's/.*available logical eraseblocks: *\([0-9]*\).*/\1/p')
V3=$(ubinfo -d 0 -n 3 | sed -n 's/^Size: *\([0-9]*\) LEBs.*/\1/p')
S=<size of ml-bootfs.itb>
echo need $(( (S + L - 1) / L )) LEBs, have $((A + V3))
```

If `have >= need`: T1 as usual. If not, the space can come from slot 1's
rootfs (vol 4), which this OS does not use (README.md, "Flash space"):
replacing it with `rootfs1-stub.squashfs` (4 KiB, the U-Boot squashfs-magic
check passes) frees its LEBs, but it **deletes the open-enet 4.19 rootfs
slot 1 holds today**: operator decision. Back it up first
(`dd if=/dev/ubi0_4 of=... ` and copy it off the box) if it may be needed.

Keep the current vol 3 for restore: `dd if=/dev/ubi0_3 of=/tmp/vol3.bak`
(and copy it off the box).

## T1. Flash vol 3 (slot 1 bootfs) - the usual procedure

```sh
scp ml-bootfs.itb rootfs1-stub.squashfs <stock box>:/tmp/
# on the box, slot 2 booted (guard: ubi.block=0,6)
grep -q 'ubi.block=0,6' /proc/cmdline || exit 1
S=$(stat -c %s /tmp/ml-bootfs.itb)
# only if T0 said so (decision): slot 1 rootfs -> stub
#   ubirmvol /dev/ubi0 -n 4
#   ubimkvol /dev/ubi0 -n 4 -N rootfs1 -s 4096 -t dynamic
#   ubiupdatevol /dev/ubi0_4 /tmp/rootfs1-stub.squashfs
ubirmvol /dev/ubi0 -n 3
ubimkvol /dev/ubi0 -n 3 -N bootfs1 -s $S -t static
ubiupdatevol /dev/ubi0_3 /tmp/ml-bootfs.itb
dd if=/dev/ubi0_3 bs=$S count=1 2>/dev/null | sha256sum   # == sha256 of the itb
```

(Volume names/types as the existing internal procedure creates them; if it
differs, use it: the image is a plain bootfs FIT like the previous mainline
images, only larger.)

## T2. Trial boot

```sh
bcm_bootstate 3; reboot
```

Expected timeline (from power-on of slot 1; U-Boot reads a ~45 MB volume, a
few seconds longer than before):

| Step | Expected | Post-code if it stops there |
|---|---|---|
| kernel + initramfs unpack | | below c0 (kernel), c0..c5 |
| rootfs found / mounted / OpenRC | < 15 s | f0..f3 (e0: the rootfs initrd did not arrive -> rescue, telnet on the USB address) |
| watchdog petting | | f4 |
| USB lifeline address (dhcpcd) | < 40 s | f5 |
| sshd | | f6 |
| Runner loaded | | f7 (e7 = insmod failed) |
| default runlevel | < 60 s | fa |
| health confirmed | | fb |

A box that never becomes reachable resets itself back to stock at the latest
~8.5 min after boot (probation 180 s + grace 300 s + watchdog); a kernel hang
resets within the U-Boot watchdog time.

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
rc-service gt-be98-wifi start
iw dev; hostapd_cli -p /run/hostapd status   # state=ENABLED
# a client joins; then
rc-service gt-be98-wifi stop                 # hostapd stops, module unloads
```

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

Build with `RESCUE=1` in the local configuration (the rootfs is still in the
image but `/init` does not mount it): expected post-codes e4, then c6..c9,
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
| f0..f3 | rootfs mount steps (hang during mount or OpenRC start) |
| e0..e4, c6..ca, ee | rescue path (see `README.md`) |
| c0..c5 or lower | kernel or early `/init` |

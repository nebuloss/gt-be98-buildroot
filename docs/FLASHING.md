# Flashing the GT-BE98 mainline OS, and going back to stock

This is the procedure for installing a release of the mainline OS on an ASUS
GT-BE98 that runs the ASUS (stock) firmware, booting it, and returning to
the stock firmware. The steps are the ones every development image has been
flashed and booted with since October 2026 (the lab helper
`nand/stock-slot1-flash.sh` and `bcm_bootstate 3`). The release
helper `gt-be98-flash.sh` is newer than that procedure: its first end-to-end
run on the box is the pre-registered test in
`docs/PREREG-RELEASE-FLASH-E2E-2026-11-02.md`. Until that test passes, treat
the helper as tested on the build host only.

Words used below:

- **stock**: the ASUS firmware (Linux 4.19), the box's normal system.
- **slot 1 / slot 2**: the box has two firmware slots on its NAND, each a
  pair of UBI volumes: slot 1 = vol 3 `bootfs1` + vol 4 `rootfs1`, slot 2 =
  vol 5 `bootfs2` + vol 6 `rootfs2`. Two metadata volumes (vol 1, vol 2)
  record which slot is **committed**, which means it boots by default.
- **one-shot boot**: the bootloader's "boot the other slot once" request.
  The stock tool `bcm_bootstate 3` sets it.

## How it works, and why you can always get back to stock

The mainline OS goes into slot 1. Stock stays in slot 2, and slot 2 stays
committed. The mainline OS is started with a one-shot boot, so the next
reset of any kind boots stock again:

| Event while mainline runs | What boots next |
|---|---|
| `reboot`, `poweroff` + power on, a panic, a watchdog reset | stock (slot 2) |
| a power cut or power cycle | stock (after a cold start the bootloader ignores the one-shot request) |
| the slot-1 boot image does not load at all | stock (the bootloader tries the other slot) |
| mainline hangs, or comes up without network or ssh | stock, within about 10 minutes (the watchdog, below) |

Where this comes from: the Broadcom bootloader (U-Boot TPL; this box has no
CFE) reads the committed slot from the metadata volumes. It boots the other
slot only when the one-shot bit is set in the always-on boot-state register
`0xff802628`, and it clears that bit as it uses it. This was read in the
vendor U-Boot source and confirmed on the device
(open-ethernet `docs/mainline-noUART-bringup.md`, section 1b).

The mainline OS never touches anything that could change this. It never
writes the slot metadata, slot 1, slot 2 or the bootloader. It writes only
bits [31:24] of `0xff802628` (its post-codes; the `devmem` in its rootfs
refuses any write to bits [23:0]). Its only NAND writes go to the stock
`/jffs` volume, through the UBI write fence
(`board/gt-be98-mainline/README.md`, "Safety rules this OS keeps").

The watchdog: U-Boot starts the SoC watchdog before the kernel. If nothing
services it, it resets the box within about 86 s. The mainline OS services
it while it boots (bounded windows), then only while the box is healthy:
an IPv4 address and sshd running. After 300 s unhealthy it stops, and the
box resets into stock. So a mainline OS that nobody can reach is back on
stock at most about 8.5 minutes after it started; the boot-time windows
(rootfs fetch, rescue shell) are bounded to 5 to 10 minutes.

## Prerequisites

On the box:

- Stock firmware running **from slot 2, with slot 2 committed**. Check it
  with the helper's `status` (step 3), or by hand on stock:

  ```sh
  grep -o 'ubi.block=0,[0-9]' /proc/cmdline            # ubi.block=0,6 = slot 2
  bcm_bootstate | grep -iE 'commit|valid'               # committed 2, valid 1,2
  ```

  If stock runs from slot 1 (`ubi.block=0,4`, committed 1), slot 1 is the
  running system and the helper refuses to flash. The ASUS firmware update
  writes the slot that is not running and commits it. So one ASUS update
  (the same official version is fine) normally moves stock to slot 2. This
  behaviour comes from the vendor flash tool as used in this project, and
  it has not been tried for this purpose. Check `status` again after the
  update.
- SSH access to stock, enabled in the ASUS web UI (Administration, System,
  Enable SSH, LAN only), with an administrator account. Below,
  `<admin>@<box>` and `-p <port>` stand for that account, the box's LAN
  address and the SSH port you chose.
- About 50 MB free in stock's `/tmp` (RAM), which is normally the case.
- Keep a copy of the official ASUS firmware for this model (the `.pkgtb`
  from ASUS) on your PC, for the last-resort recovery.

On your PC: `ssh`, `sha256sum`, and the release's **flash kit**: a
directory produced by `board/gt-be98-mainline/flash/build-flash-kit.sh`.

| Kit file | What |
|---|---|
| `gt-be98-flash.sh` | the helper; runs on stock |
| `ubirsvol`, `ubiupdatevol` | static UBI tools (mtd-utils of the build), used when stock lacks them |
| `rootfs.squashfs`, `ml-bootfs.itb` | the OS and its boot image, built together |
| `ml-bootfs.info` | the build's description of the images (versions, build id) |
| `IMAGES.sha256` | the sha256 of the two images |
| `SHA256SUMS` | the sha256 of every file in the kit |

The kit contains proprietary vendor firmware, and an image built with SSH
host keys or a web UI password contains those too. **Never publish a kit
or an image.** Hand them over privately.

### Building the kit (release maintainer)

Build as in `board/gt-be98-mainline/README.md` ("Build"), with a release
configuration in `local.conf`:

- `SSH_AUTHORIZED_KEYS`: the owner's public keys. This decides who can log in.
- `ROOTFS_URL`: empty, or the owner's own server. The OS boots from slot 1's
  vol 4; the URL is only a fallback.
- `NAND=rw-jffs`: needed for `/jffs` persistence; this is the default.
- `WEBUI_DIR` and `WEBUI_PASSWORD` (or `_HASH`), if the web UI is part of
  the release.
- no lab addresses (`SYSLOG_REMOTE`, `NETCONSOLE`, fallbacks) unless the
  owner wants them.

Then run:

```sh
rtk sh board/gt-be98-mainline/build.sh
sh board/gt-be98-mainline/flash/build-flash-kit.sh    # -> $OUT/images/flash-kit (KIT_DIR=... to change)
```

The kit builder refuses to run when the rootfs or the itb is not the one
`ml-bootfs.info` records. The itb's initramfs accepts from vol 4 only the
rootfs it was built with. Copy the two values of `IMAGES.sha256` into the
release notes.

## 1. Verify the images (on your PC)

```sh
cd flash-kit
sha256sum -c SHA256SUMS          # every line OK
cat IMAGES.sha256                # must equal the two sha256s in the release notes
```

Stop if either check fails. The second check is the one that matters: a
`SHA256SUMS` that comes with the files proves only that the files match
each other, not that they are the release.

## 2. Copy the kit to stock

Stock's SSH server may not offer `scp`. Plain `ssh` works always:

```sh
B="-p <port> <admin>@<box>"
ssh $B 'mkdir -p /tmp/gtb'
for f in gt-be98-flash.sh ubirsvol ubiupdatevol rootfs.squashfs ml-bootfs.itb ml-bootfs.info IMAGES.sha256 SHA256SUMS; do
	ssh $B "cat > /tmp/gtb/$f" < "$f" || echo "FAILED: $f"
done
ssh $B 'cd /tmp/gtb && chmod +x gt-be98-flash.sh ubirsvol ubiupdatevol && sha256sum -c SHA256SUMS'
```

All lines must say OK. `/tmp` is in RAM: a reboot of stock empties it, and
then you copy the kit again.

## 3. Check the box, then a dry run

On stock (`ssh $B`), always with the stock busybox. On this firmware
`/usr/sbin/sh` is a different program, so do not use `sh` alone:

```sh
cd /tmp/gtb
/bin/busybox sh ./gt-be98-flash.sh status
R=$(sed -n 's/  rootfs.squashfs$//p' IMAGES.sha256); I=$(sed -n 's/  ml-bootfs.itb$//p' IMAGES.sha256)
/bin/busybox sh ./gt-be98-flash.sh flash --check rootfs.squashfs $R ml-bootfs.itb $I
```

`status` must show `booted slot 2`, `committed 2` and `reset_reason: 34`.
The dry run checks the running system, the volumes, the space and the
image sha256s, prints the plan and writes nothing. It ends with
`check only: nothing written`. If you would rather not trust the copied
`IMAGES.sha256`, type the two sha256s from the release notes instead of
`$R` and `$I`.

Refusals and their meaning:

| Message | Meaning, what to do |
|---|---|
| `not the stock firmware` | you are on the mainline OS: `reboot` first |
| `stock is running from slot 1` / `committed slot is '1'` | see Prerequisites |
| `sha256 mismatch` | a damaged copy or a wrong file: copy it again (step 2) |
| `vol 3/4 are not bootfs1/rootfs1`, `LEB size` | not the NAND layout this release was made for: stop and report it |
| `not enough free LEBs` | the UBI device lacks space for the plan: report the `status` output |

## 4. Flash slot 1

```sh
/bin/busybox sh ./gt-be98-flash.sh flash rootfs.squashfs $R ml-bootfs.itb $I
```

This sizes vol 4 (265 LEBs, 32.1 MiB), writes the rootfs, reads it back
and compares the sha256. Then it writes the boot image into vol 3 (it grows
vol 3 only if needed) and checks it the same way. It ends with `FLASH-OK`.
Nothing else is written. Stock keeps running from slot 2, so an interrupted
flash (power cut, lost session) affects slot 1 only. In that case run step
4 again. Do not boot slot 1 after a failed read-back.

Updating to a newer release is the same steps 1 to 4 from stock. Flashing
from the mainline OS is not supported: the helper refuses, and the mainline
OS keeps slot 1 read-only.

## 5. Boot the mainline OS

```sh
/bin/busybox sh ./gt-be98-flash.sh boot --clear-postcode
```

The helper checks the preconditions again (slot 2 booted and committed,
`reset_reason` 34, a squashfs in vol 4, no lab trial markers). It then runs
`bcm_bootstate 3`, checks that the one-shot request was taken
(`reset_reason` reads 1), and reboots. If the request was not taken, it
does not reboot.

`--clear-postcode` first sets the post-code byte (bits [31:24] of
`0xff802628`) to 0. A reading after a failed boot then shows how far that
boot got (Recovery, below). The helper writes the register back with bits
[23:0] exactly as it read them, and it re-reads the register. If [23:0]
changed, it stops without arming anything. Leave the option out and the
helper writes nothing to that register: only `bcm_bootstate` writes it.

After a power-on, stock's `reset_reason` is not 34. The helper then refuses
(`expected 34`): reboot stock once and run step 5 again. It is not known
whether a one-shot boot armed after a cold start works, so the helper does
not try it.

What to expect: the box is dark for 1 to 2 minutes. The mainline OS then
gets an address by DHCP on the LAN port, and on the USB-Ethernet lifeline
if an adapter is plugged in. Log in with the key that the release was built
with:

```sh
ssh root@<mainline address>
gt-be98-status                                  # release, health, modules, addresses
cat /etc/gt-be98-boot-info                      # BOOT_ROOT_SOURCE=ubi:rootfs1
tr -d '\000' < /proc/device-tree/gt-be98,build-id; echo   # = "build id (DT)" in ml-bootfs.info
```

`BOOT_ROOT_SOURCE=ubi:rootfs1` means the OS came from vol 4 and its
sha256 matched the one built into the boot image. A different source
(`http:`, `usb-...`) means vol 4 was not used: re-flash.

## 6. Back to stock (rollback)

From the mainline OS:

```sh
reboot
```

The box comes back on stock (slot 2) after 2 to 3 minutes. A power cycle
does the same. Check on stock:

```sh
/bin/busybox sh /tmp/gtb/gt-be98-flash.sh status   # if the kit is still there (it is not after a reboot)
grep -o 'ubi.block=0,[0-9]' /proc/cmdline         # ubi.block=0,6
bcm_bootstate | grep -iE 'commit|valid'            # committed 2
```

The mainline OS stays in slot 1, unused. **To boot it again**, copy
`gt-be98-flash.sh` to stock's `/tmp/gtb` (as in step 2; the other files are
not needed) and run step 5. No re-flash is needed.

What the mainline OS leaves on the box: slot 1 (vol 3, vol 4, and vol 4's
new size), and its saved settings in stock's `/jffs` (`/jffs/mainline-os/`).
Stock ignores both. To remove the saved settings, run on stock:
`rm -rf /jffs/mainline-os`. Overwriting slot 1 with an ASUS image happens
with the next ASUS firmware update made from stock, which writes the slot
that is not running (see Prerequisites, same caveat). After that update,
stock runs from slot 1.

## 7. If the mainline OS does not come up

1. **Wait.** Without a successful boot, the box returns to stock by itself:
   within about 2 minutes if the kernel hangs or panics, and within about
   10 minutes if userspace starts but the box never becomes reachable.
2. **Power cycle** if the box is still dark after 15 minutes. A cold start
   always boots the committed slot (stock). This is safe at any time:
   the mainline OS never changes what the bootloader boots.
3. **Read the post-code** back on stock (best when step 5 used
   `--clear-postcode`):

   ```sh
   devmem 0xff802628 32           # top byte = the last post-code of the failed boot
   ```

   Decode it with the table in `board/gt-be98-mainline/README.md`
   ("Boot, services, post-codes"). Examples: `00` = the kernel never
   reached its first code (boot image or very early kernel); `e0` to `eb`
   = the boot stopped in `/init`, mostly because the rootfs in vol 4 was
   missing or did not match (re-flash); `fd` = the OS ran
   but stayed unhealthy (no address or no sshd: check the LAN cable and
   the DHCP server); `fe` = a clean reboot. Never write to this register
   by hand.
4. **Re-flash** (steps 2 to 5) if the post-code points to the images, and
   report the post-code, the `status` output and `ml-bootfs.info` with any
   bug report.
5. **Last resort, stock itself does not come back** after a power cycle.
   This is not expected: nothing in this procedure or in the mainline OS
   writes slot 2, the metadata or the bootloader. Use the ASUS firmware
   rescue mode with the official firmware file (ASUS documents it: reset
   button held at power-on, then the ASUS Firmware Restoration tool or
   TFTP). This path has not been tested on this unit.

## Making the mainline OS the default boot

With this release, the mainline OS runs until the next reset, and the box
then returns to stock. This includes a power cut. That is the safety
mechanism described above, not a bug. The rest of this section lists the
ways to change it. **None of them is part of this release**, and nobody
should apply one by hand.

| Option | How | Risk | Status |
|---|---|---|---|
| A. One-shot (today) | step 5 after every reset | none known; the box returns to stock after every reset, including a power cut | this release |
| B. Stock arms mainline at every boot | a stock-side `/jffs` boot script runs step 5 automatically. It stops after N failed mainline boots, counted with the post-code byte (`fb` = healthy, `fd`/`e*`/`00` = failed). An escape file stops it | every boot passes through stock first (2 to 3 min, stock radios up briefly with stock's own settings); depends on stock's JFFS scripts option and on stock behaviour that an ASUS update can change; first boot after a power cut needs an extra stock reboot (`reset_reason` not 34, see step 5) | design only (`board/gt-be98-mainline/PERSISTENCE.md`, "Promotion", item 2); the recommended next step |
| C. Commit slot 1 | `bcm_bootstate +1` on stock | every reset, including a watchdog reset of a hung mainline, boots mainline again. The mainline OS cannot switch back by itself (it never writes the slot metadata or bits [23:0] of the boot-state register), and the bootloader has no boot counter (`CONFIG_BCM_BOOTSTATE_FALLBACK_SUPPORT` and `BOOTCOUNT` are not built in), so a bad image loops until the ASUS rescue mode, which is untested on this unit | **do not**; acceptable only with a tested way back that needs no running OS |
| D. Change the bootloader (boot counter, A/B fallback) | rebuild and flash the loader partition | a failed loader write leaves the box unbootable without serial/JTAG, which this box does not expose | out of scope |

For a product, mainline should eventually boot by default. With the
bootloader as shipped, option B is the only one that keeps "any failure
ends on stock". It needs its own implementation and its own pre-registered
test: cold start, failed-boot counter, escape file, and an ASUS update with
the script installed. Option C would require a tested independent recovery
first (`PERSISTENCE.md`, "Promotion", item 1).

## Do not

- write bits [23:0] of `0xff802628`, by hand or from a script. A stray
  one-shot bit there makes the box boot slot 1 after every reset, and only
  a power cycle ends that.
- `bcm_bootstate +1` (commit slot 1): see option C.
- flash slot 2, the metadata volumes or the loader partition: the way back
  depends on them.
- leave the lab trial markers `/data/open_enet` or `/data/.trial-armed` on
  stock (the helper refuses while they exist).

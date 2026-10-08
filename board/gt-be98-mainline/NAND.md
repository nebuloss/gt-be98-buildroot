# GT-BE98 mainline OS - NAND, PHASE 1: read-only

Goal: persistence for the mainline OS in the stock `/jffs` (a UBIFS volume
of the single UBI device on the NAND) **without the mainline OS ever writing
the NAND**. Mainline reads; stock writes.

Opt-in: `NAND=ro` in the local configuration (default `off`: the DT has no
NAND node, exactly as before). There is no write mode.

## Safety layers (all four must fail for a write to reach the flash)

1. **DT**: both NAND partitions (`loader` 0..2 MiB, `image` 2..255 MiB,
   stock's `mtdparts`) carry `read-only`: no `MTD_WRITEABLE`, so
   `mtd_write`/`mtd_erase` return `-EROFS` at the MTD layer
   (`post-image.sh` refuses to build a DTB with a writable partition).
2. **Kernel patch** `patches/linux/0001-mtd-rawnand-brcmnand-read-only-unless-allow_write.patch`:
   brcmnand refuses program, copy-back and erase (`-EROFS`) at every entry
   point (page/OOB writes, native commands, low-level opcodes) and never
   starts such a command, unless `brcmnand.allow_write=1`. The image's
   command line is forced and does not have it. This layer also covers the
   NAND core's own writes (on-flash BBT creation/refresh), which bypass the
   MTD flags: such a write fails and the NAND simply does not probe.
3. **UBI**: attached on a read-only MTD it runs in read-only mode (no
   wear-leveling, scrubbing, erase); `gt-be98-jffs` checks
   `/sys/class/ubi/ubi0/ro_mode` = 1 and detaches otherwise. No fastmap
   support (`CONFIG_MTD_UBI_FASTMAP` off), so a stock fastmap is ignored, never
   rewritten.
4. **UBIFS** mounted `-o ro`; **userspace** has no writing tools (mtd-utils
   limited to `mtdinfo`, `nanddump`, `ubiattach`, `ubidetach`, `ubinfo`; the
   others are removed from the image even if pulled in).

## ECC / geometry: from the straps, as stock

The stock DT node (`brcm,nand-bcm63xx`, `brcm,nand-bcmbca`,
`brcm,brcmnand-v7.1`) has no ECC properties: the vendor driver uses the
configuration the boot ROM and the loader put in the controller (boot
straps), with `nand-on-flash-bbt`. Mainline does the same with
`brcm,nand-ecc-use-strap` on the `nand@0` chip-select node: ECC strength,
step size (512 B / 1 KiB sector) and spare-area size are read back from
`ACC_CONTROL` (0xff801850). The mainline controller node is the one already
in `bcm6813.dtsi` (`nand-controller@1800`, bcmbca glue). So nothing is
hard-coded; the stock values below are what the mainline log and
`gt-be98-nandcheck` must match.

## What the orchestrator runs on STOCK first (read-only)

```sh
scp board/gt-be98-mainline/nand/stock-nandinfo.sh <stock>:/tmp/
ssh <stock> '/bin/busybox sh /tmp/stock-nandinfo.sh' > stock-nand.txt
```

It prints `/proc/cmdline`, `/proc/mtd`, every MTD's size/erasesize/
writesize/oobsize/ecc_strength/ecc_step_size/flags/bad_blocks/bbt_blocks,
the NAND/UBI kernel log, `ubinfo -a` and the volume table, the sha256 of the
static volumes (bootfs1/bootfs2), the `/jffs` mount, a **read-only** devmem
dump of the controller configuration registers (0xff801800..0xff80187c), the
NAND DT node and whether `nanddump` exists. Send `stock-nand.txt` back: the
mainline values are checked against it (expected: the same erasesize,
writesize, oobsize, ECC strength/step, bad blocks, the same UBI volumes, the
same static-volume sha256s).

For PHASE 2 (ECC/OOB layout), on stock, if `nanddump` exists:

```sh
# page P of the UBI partition (mtdN = "image" in /proc/mtd), raw and corrected
nanddump -q -n --oob --bb=dumpbad -s $((P * WRITESIZE)) -l WRITESIZE -f /tmp/p-raw.bin /dev/mtdN
nanddump -q    --oob --bb=dumpbad -s $((P * WRITESIZE)) -l WRITESIZE -f /tmp/p-ecc.bin /dev/mtdN
```

and on mainline `gt-be98-nandpage image P 1 raw > p-raw.bin` (and `ecc`),
then `cmp`.

## On the mainline OS

`gt-be98-jffs` (boot runlevel, before sshd, dhcpcd, chronyd, syslogd and the
web UI):

1. finds the `image` MTD, refuses if it is writable;
2. `ubiattach` (read-only mode, verified), mounts `ubi0:jffs2` read-only on
   `/jffs`;
3. applies `/jffs/mainline-os/`: `state.tgz` (checked against
   `state.tgz.sha256` when present), then an `overlay/` tree; only the paths
   in `ALLOW_PATHS` (`/etc/conf.d/gt-be98-jffs`): `/etc/webui` (webui.db,
   platform.conf, auth.conf, ssh/), the SSH host keys, `/etc/ssh/authorized_keys`,
   `/root/.ssh`, `/var/lib/dhcpcd`, `/var/lib/chrony`. Missing = the image
   defaults (kept as the fallback).

So SSH host keys and the web UI password can live in `/jffs` instead of the
served rootfs (PERSISTENCE.md, "secrets off the served rootfs"): once a
state is stored, the image values are only the fallback.

Checks: `gt-be98-nandcheck` (add `--sha` for the static-volume sha256s),
`gt-be98-nandpage` (raw page + OOB dumps).

## Saving state (stock writes, never mainline)

```sh
# 1. on the lab host, while the box runs mainline
ssh root@<box> gt-be98-save > state.tgz
# 2. next stock boot (trial over, or the box reset into stock)
sh board/gt-be98-mainline/nand/stock-apply-state.sh state.tgz <user@stock> [port]
#    -> /jffs/mainline-os/state.tgz + state.tgz.sha256 (previous kept as .prev)
# 3. next mainline boot: gt-be98-jffs applies it
```

`stock-apply-state.sh` refuses a target whose command line is not stock's
(`ubi.block=`), checks the sha256 after the copy, and writes through a
temporary file plus `mv`, then `sync`.

## Expected mainline log (to compare)

```
brcmnand ...: NAND controller v7.1 ...
nand: device found, Manufacturer ID ..., Chip ID ...
nand: <size> MiB, SLC, erase size: <n> KiB, page size: <n>, OOB size: <n>
brcmnand ...: <size>MiB total, <n>KiB blocks, <n>KiB pages, <n>B OOB, 8-bit, BCH-<n>
Bad block table found at page ..., version 0x..
2 fixed-partitions partitions found on MTD device brcmnand.0
ubi0: MTD device <n> is write-protected, attach in read-only mode
UBIFS (ubi0:<n>): mounted "jffs2" ..., R/O mode
```

A missing "Bad block table found" (BBT not recognised) means the probe
failed on the refused BBT write: the NAND stays off; report it.

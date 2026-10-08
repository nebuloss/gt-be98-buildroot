# GT-BE98 mainline OS - persistence and promotion (P2 design)

Status: design. Level 0 and 1 are implemented in P1; levels 2-4 are not and
must not be enabled without the reviews listed. Promotion to a committed slot
is documented only.

## Constraints

- NAND writes from mainline are forbidden until proven safe.
- The NAND holds one UBI device (`mtd` "image", 253 MiB) with **every** volume:
  both slots (bootfs/rootfs 1 and 2), the slot metadata (vol 1, 2), `data`,
  `defaults`, `jffs2`. Slot 2 (stock) is the automatic fallback of every
  trial.
- UBI is not per-volume on the flash: wear-leveling, scrubbing and bad-block
  handling move PEBs of *any* volume. A read-write UBI attach from mainline
  can therefore rewrite PEBs that belong to slot 2 or to the metadata, even if
  mainline never opens those volumes. Any read-write use of the NAND from
  mainline is a decision about the whole device, not about one volume.
- The DT of this OS has no NAND node at all.

## Levels, safest first

### Level 0 - volatile (implemented, default)

Root = squashfs (read-only, in the kernel image) + overlayfs on tmpfs. All
changes vanish at reboot. Configuration that must survive is baked in at
build time (local configuration on the build host: SSH keys, host keys,
fallback addresses, syslog target) or pulled at boot.

### Level 1 - off-NAND persistence (implemented, optional)

- `gt-be98-persist`: a USB storage device labelled `GTBE98-DATA` (ext4/vfat)
  is mounted on `/data`: per-boot log directories, dmesg at boot and shutdown,
  and `/data/etc-overlay/` copied over `/etc` at boot. A USB stick is
  disposable and independent of the router's flash; the worst case is a
  corrupted stick.
- `SYSLOG_REMOTE`: all logs to a lab host (UDP). Survives a hard reset of the
  box, which no local log does (DRAM is scrambled on reset, so ramoops cannot
  help either).
- Pull config over the network (not automated yet): a boot service could
  fetch `etc-overlay.tar` from a lab URL given at build time and unpack it
  over `/etc`. Same trust level as the build host.

Evidence: nothing in levels 0/1 opens an MTD device (no NAND node, no MTD
userspace tools in the rootfs).

### Level 2 - read-only access to the stock `/data` volume (next step)

Goal: read the stock configuration (e.g. `/data` files, nvram exports) from
mainline, without any possibility of a NAND write.

Needed changes, all build-time options, off by default:

1. DT: the NAND controller node (`brcm,nand-bcm63138` / BCMBCA compatible,
   from the vendor DT) with the **exact** ECC geometry stock uses
   (`nand-ecc-strength`, `nand-ecc-step-size`, OOB layout) and **no**
   `nand-on-flash-bbt`: mainline's on-flash BBT code creates and writes a
   BBT when it does not recognise one (`nand_bbt.c`, `NAND_BBT_CREATE` /
   `NAND_BBT_WRITE`), bypassing the MTD write-protection flags. Without the
   property the BBT is built in RAM from the OOB markers only.
2. DT: the `image` partition (and the `loader` partition) marked
   `read-only;` -> `MTD_WRITEABLE` cleared -> `mtd_write`/`mtd_erase` return
   `-EROFS`, and UBI attaches in **read-only mode** (`ubi->ro_mode`, no
   wear-leveling, no scrubbing, no erase of empty PEBs).
3. Kernel: a small out-of-series DEBUG patch to `brcmnand` that refuses every
   program and erase command (`-EROFS` in `brcmnand_write` /
   `brcmnand_erase`), so that a missed path (BBT, a driver bug) cannot reach
   the flash. This is the real guarantee; 1 and 2 are defence in depth.
4. Userspace: `ubiattach -r` / `ubi.mtd=image` with read-only, then
   `mount -t ubifs -o ro ubi0:data /mnt/stock-data`. No `mtd-utils` writing
   tools in the image (`flash_erase`, `nandwrite`, `ubiformat`, `ubimkvol`
   left out).

Validation before anything uses it:

- QEMU/bench: run the patched brcmnand against a NAND simulator image of a
  stock dump with the controller ops traced; zero program/erase.
- On the box (trial, slot 1): attach read-only, compare `ubinfo -a` and
  a sha256 of each static volume (bootfs2, rootfs2) with the values read on
  stock; read `/data` files and compare. ECC error counters must stay 0.
- Then back on stock: compare `nanddump` of the metadata and slot-2 PEBs
  with a dump taken before the trial: identical.

### Level 3 - a dedicated persistent volume (needs a decision)

Read-write data on the NAND from mainline, e.g. a new UBI volume
`mlos-data` (UBIFS, a few MiB). Because of the UBI property above, this means
running mainline's UBI read-write on the whole device. Preconditions: level 2
validated over many boots, brcmnand write path reviewed against the vendor
driver (ECC, OOB, bad-block marking, page programming order), an independent
recovery path for slot 2 (a full NAND backup and a tested restore from the
bootloader). Alternative that avoids it: keep level 1 (USB) for persistence.

### Level 4 - overlay upper on persistent storage

Once level 1 or 3 exists: mount the overlay upper layer on it instead of
tmpfs (`/init` option), so `/etc` and installed files persist. Keep a
"factory reset" knob (ignore the upper layer) in the initramfs.

## Promotion of the image to a committed slot (document only, do not do)

Today the mainline image is only ever booted **once** (`bcm_bootstate 3`)
from the committed stock slot 2. Any reset (watchdog, reboot, panic) returns
to stock: this is the whole safety story. Committing slot 1 changes that:
U-Boot would boot mainline after every reset, and a mainline that hangs early
would be reset into mainline again.

Before promotion is acceptable:

1. A way back that does not need mainline to work: ASUS/BCA rescue mode (reset
   button + web recovery or TFTP in U-Boot) tested on this unit, and a stock
   `.pkgtb` at hand.
2. A boot-failure counter that falls back to slot 2: e.g. mainline asks for a
   one-shot boot of slot 2 on its next reset when it detects repeated failed
   boots, or the inverse (stock stays committed, and a stock-side service
   re-arms `bcm_bootstate 3` after each good mainline boot, so a failed
   mainline boot always lands on stock). The second keeps every rule of
   today (no write to `0xff802628[23:0]` from mainline) and is the
   recommended path: "always boot mainline, fall back to stock" without
   committing slot 1.
3. Level 2 at least, so that mainline can read the slot metadata and report
   which slot is committed and valid.
4. The commit itself would be done from **stock** with the open metadata writer
   (`board/gt-be98/flash/open-flash.sh`: seq bump + CRC, then the committed
   field), never from mainline.

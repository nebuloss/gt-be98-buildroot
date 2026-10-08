# GT-BE98 NAND - restoring the raw backup (G5, restore half)

Status: procedure and tool tested **only under nandsim** (rehearsal gates
`restore_ran`, `restore_bit_exact`, `restore_entries_cleared`,
`restore_refused_while_attached`, `results-20261008.txt`). Never run on the
box so far.

## The backup (G5, backup half)

`~/oe-tool/backup/nand-raw-20261008/` on the build host, taken from mainline
(reads proven identical to stock), `SHA256SUMS` inside:

| File | What |
|---|---|
| `mtd0-loader-raw-oob.bin`, `mtd1-image-raw-oob.bin` | `nanddump --noecc --oob`: page data + the controller's 108-B spare exactly as stored, uncorrected (the restore source) |
| `mtd0-loader-ecc-oob.bin`, `mtd1-image-ecc-oob.bin` | `nanddump --oob`: corrected page data + spare (reference; page data used for the nandsim rehearsal) |

Take a fresh `mtd1` raw dump right before every read-write session on the box
(G8): a restore brings the whole UBI partition back to the moment of the dump,
including whatever stock changed since.

## R0 - file level (routine)

- Mainline state: `gt-be98-save` archives (`/jffs/mainline-os/state.tgz` and
  its `.prev`).
- Stock `/jffs`: `tar` it from stock before a session; restore it from stock.

## R1 - raw, PEB-granular, bit-exact (from the mainline OS)

`gt-be98-nandrestore` (nand-phase2-kit) compares every eraseblock of the
partition with the backup in raw mode and rewrites **only the eraseblocks that
differ**: erase, program each non-blank page raw (data + spare, so the original
ECC bytes go back unchanged), read back and compare. Writes pass the write
fence through `debugfs ubi/fence_restore`, which the kernel refuses while a UBI
device is attached to the chip.

Requirements: an image built with `NAND=rw-jffs` (the `image` partition
writable; `loader` is read-only in every image and is never restored, nothing
ever writes it), mainline booted from netroot (the OS does not run from the
NAND), UBI detached.

```sh
# box on mainline
scp nand-phase2-kit/* mtd1-image-raw-oob.bin root@<box>:/tmp/gtb/   # 280 MB, RAM
ssh root@<box>
rc-service webui stop 2>/dev/null; rc-service gt-be98-jffs stop     # unmount /jffs, detach UBI, allow_write=0
cd /tmp/gtb && sha256sum mtd1-image-raw-oob.bin                       # == SHA256SUMS of the backup
./gt-be98-nandrestore --dry-run mtd1-image-raw-oob.bin /dev/mtd1      # lists the differing PEBs
echo 1 > /sys/module/brcmnand/parameters/allow_write
./gt-be98-nandrestore mtd1-image-raw-oob.bin /dev/mtd1                 # rewrites them, verifies
echo 0 > /sys/module/brcmnand/parameters/allow_write
./gt-be98-nandrestore --dry-run mtd1-image-raw-oob.bin /dev/mtd1      # expect: 0 differing
reboot                                                                 # one-shot trial over: stock
```

Then on stock: `stock-nandinfo.sh` (UBI attaches, 0 corrupted, the static
volume sha256s as in the backup).

Restore of a single PEB: `--peb N`. Bad blocks (now or in the backup) are
reported and skipped.

## Not from stock, not from the bootloader

- **Stock**: its UBI device is attached to the `image` partition all the time
  (the stock rootfs is a `ubiblock` on rootfs2, `/data` and `/jffs` are
  mounted), so rewriting eraseblocks underneath it is unsafe; stock has no
  write fence; stock's 4.19 lacks the `MEMREAD` ioctl the tool uses for raw
  verification. A stock-side raw restore is therefore **not supported**.
- **Bootloader**: U-Boot has `mtd`/`ubi` commands but the box has no
  accessible UART. The bootloader path left is the ASUS rescue mode (reset
  button + TFTP of a stock `.pkgtb`), which reflashes the firmware slots, not
  `/jffs`: last resort, followed by R0 for `/jffs`.

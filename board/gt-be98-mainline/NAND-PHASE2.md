# GT-BE98 mainline OS - NAND PHASE 2: mainline read-write on /jffs only (DESIGN, not implemented)

Status: design only. Nothing here is built. Phase 1 (read-only, NAND.md)
stays the default and the fallback; phase 2 is opt-in per image and only
after every GO criterion below is met.

## Gate status

| Gate | Status |
|---|---|
| Validation step 1, layout (criteria **G1-G4**) | **PASSED** 2026-10-08, see below |
| G5-G9 (rehearsal, sacrificial volume, real session, backup/restore) | not started; phase 2 implementation **on hold until the owner approves** |

### G1 (layout) PASSED - 2026-10-08

`nand-ecc-compare.sh` run read-only on the stock firmware and on the
mainline OS (itb 799b2fc9, NAND=ro), same static tools
(`nanddump` eb8195dd..., `gt-be98-nandtool` cbf422df...,
`nand-ecc-compare.sh` b0bba3cf...).

Archives (orchestrator, `jobs/ab703faf/tmp/`):

| Archive | sha256 |
|---|---|
| `ecccmp-stock.tgz` | `d463d6730b5fa4745faedf7b1aad458c0015d1ffb6a2b9a3da4fb1f39aad41b7` |
| `ecccmp-mainline.tgz` | `5edae76fac772e8f645d329f93ebab45525a5d742e58cc1ffbc59a6ff4966698` |

Results (identical on both systems unless noted):

- **G1 geometry**: writesize 2048, OOB 108, erasesize 131072, 64 pages per
  block, ECC strength 8, step 512.
- **G2 decode**: the 7 blocks (bootfs2 LEB 0 = PEB 1658, bootfs2 LEB 57 =
  PEB 1513, rootfs2 LEB 0 = PEB 909, jffs2 LEB 0 = PEB 869, free PEB 0,
  loader blocks 0 and 1) have identical `data_ecc` sha256 on stock and
  mainline (the PEB map was the same on both).
- **G3 OOB layout**: identical `data_raw` and `oob_raw` sha256 for all 7
  blocks; `oob_bits_differing` 0 everywhere.
- **G4 errors**: no uncorrectable read, `ecc_failures` 0 before and after on
  both; the only bitflip in the sample is 1 bit in loader block 1 (worst
  sector 1), seen identically by both drivers.
- **Counters**: stock `corrected_bits` stayed 0 (image and loader) through
  the run; mainline went 64 -> 134 on `image` (bits corrected silently in
  the PEB-header reads of the whole partition, none in the dumped blocks)
  and 0 -> 2 on `loader` (the 1-bit flip, counted per read). This confirms
  the counting-semantics explanation of NAND.md: the drivers decode the same
  data; only mainline's counter reports sub-threshold corrections.

## The problem

`/jffs` is the UBIFS volume `jffs2` (vol 13) of the **one** UBI device on
the `image` partition, which also holds both slots (bootfs/rootfs 1 and 2),
the boot metadata (vol 1, 2), `data` and `defaults`. A read-write UBI attach
is device-wide:

- **wear-leveling** moves data of *any* volume (copy to another PEB, erase
  the old one) when erase counters drift apart: stock reports max/mean EC
  4133/1119 with a WL threshold of 4096, so moves are not hypothetical;
- **scrubbing** rewrites any PEB a read found with too many bitflips;
- **attach-time repairs** erase corrupted/unknown PEBs, and **bad-block
  marking** updates the on-flash BBT (a NAND-core write, outside UBI);
- **UBIFS** on the jffs2 volume can rewrite its own superblock/master/LPT
  areas on a read-write mount.

So "write only /jffs" needs an explicit fence below UBIFS, and proof that
mainline's write path produces pages stock decodes.

## Design

1. **Two-level switch**, both off by default, both needed:
   - DT/image: `NAND=rw-jffs` (new local.conf value) makes the `image`
     partition writable; `loader` stays `read-only` always;
   - kernel command line: `brcmnand.allow_write=1` (the phase-1 patch) and
     `ubi.fence=jffs2` (new). Without both, phase-1 behaviour.
2. **UBI write fence** (new kernel patch, `drivers/mtd/ubi`): with
   `ubi.fence=<volume names>`, UBI may only
   - write/erase a PEB that is free or mapped to a fenced volume;
   - take PEBs from the free pool for fenced volumes;
   and it refuses (logs, does not do):
   - wear-leveling moves and scrubbing of PEBs owned by any other volume
     (skipped; stock does its own WL when it runs);
   - erasing corrupted/unknown PEBs found at attach (left to stock);
   - `mtd_block_markbad()` (no BBT write from mainline ever: a block that
     goes bad under mainline is reported and left to stock);
   - any layout-volume (volume table) update: no volume create/remove/resize
     from mainline.
   The fence state is exported (`/sys/class/ubi/ubi0/fence`) and
   `gt-be98-jffs` mounts `/jffs` read-write only if it reads the expected
   fence, otherwise read-only (phase 1).
3. **UBIFS**: mount `rw` only after a clean read-only mount succeeded in the
   same boot; no format upgrade (refuse if the superblock flags would
   change); `sync` on every state save; clean unmount in the shutdown
   runlevel *before* the watchdog stops being petted.
4. **What mainline writes**: only `/jffs/mainline-os/` (the state the save
   script packs today), so stock remains the owner of the rest of `/jffs`.
5. **Recovery first**: before the first read-write boot, a full raw backup
   of the NAND (`gt-be98-nandpage`/`nanddump` of `loader` and `image`, data
   + OOB, raw and corrected, ~270 MB) is kept off the box, and a restore
   path that does not need mainline is tested (stock `ubiupdatevol` of the
   affected volumes / bootloader recovery).

## Validation plan (in order; each step gates the next)

1. **Layout (read-only)**: NAND.md "ECC comparison" on stock and mainline.
2. **Offline rehearsal**: the full raw NAND image (step 5 backup) loaded into
   `nandsim` in a QEMU/x86 kernel with the fenced UBI: attach RW, mount
   jffs2, write/delete files, unmount, detach, reboot cycles, power cuts in
   the middle of writes; then diff the image against the original and list
   every changed PEB with its owner.
3. **Write encode compatibility (real NAND, sacrificial volume)**: stock
   creates a small dynamic volume `mltest` (2 MiB) in the free space; a
   mainline image with `ubi.fence=mltest` writes patterns into it; stock
   then reads them (ECC decode by the stock driver) and mainline reads
   stock-written patterns; finally stock removes the volume.
4. **Real /jffs, supervised**: one mainline boot with `ubi.fence=jffs2`,
   writes `/jffs/mainline-os` only, clean unmount, then a stock boot.
5. **Soak**: repeated save/reboot cycles alternating stock and mainline,
   with induced watchdog resets during writes.

## GO / NO-GO criteria

GO requires **all** of:

| # | Criterion | Evidence |
|---|---|---|
| G1 | Same geometry and ECC: writesize 2048, OOB 108, BCH-8/512, same BBTs | both `report.txt` geometry lines |
| G2 | Stock and mainline decode the same data: identical `data_ecc` sha256 for bootfs2, rootfs2, loader blocks | ECC comparison |
| G3 | Raw OOB identical between the drivers except the bitflips listed in `.flips` (no layout difference: ECC bytes in the same positions) | `oob_raw` sha256 / byte diff |
| G4 | No uncorrectable read anywhere, worst sector ≤ 2 flips, `ecc_failures` delta 0 on both | ECC comparison counters |
| G5 | Rehearsal: only PEBs that were free or owned by jffs2 changed; EC headers changed only on those; volume table, metadata1/2, bootfs/rootfs, data, defaults unchanged; no BBT change | nandsim image diff |
| G6 | Rehearsal power cuts: UBI attaches and UBIFS mounts afterwards on both the fenced mainline and an unmodified UBI | nandsim runs |
| G7 | Sacrificial volume: stock reads mainline-written pages bit-identical with 0 uncorrectable and ≤ 1 flip/sector; the reverse too | step 3 |
| G8 | After the first real RW session, stock boots normally: UBI 0 corrupted, `/jffs` mounts rw cleanly, the static-volume sha256s (metadata1/2, bootfs1/2) unchanged, `ubinfo` unchanged except jffs2 usage and free counts | stock-nandinfo.sh before/after |
| G9 | Backup taken and restore tested without mainline | step 5 of the design |

NO-GO on **any** of:

- any uncorrectable read or `ecc_failures` increase on either side;
- any raw-OOB *layout* difference (beyond single unstable bits), or a
  different spare-area size / sector size / ECC level;
- any PEB outside the fence changed in the rehearsal, a BBT write attempt, a
  volume-table update, or a UBIFS superblock format change;
- stock reporting corrupted PEBs, UBIFS recovery errors or a changed static
  volume after a mainline session;
- the fence not visible/verifiable at runtime (then mainline stays read-only).

Until GO, persistence stays as implemented in phase 1: mainline reads
`/jffs/mainline-os`, stock writes it (`gt-be98-save` + `stock-apply-state.sh`).

# GT-BE98 mainline OS - NAND PHASE 2: mainline read-write on /jffs only

Status: **approved and implemented** (2026-10-08), every switch default-OFF;
validated in simulation (G5 restore, G6). Nothing has been enabled on the
box. Phase 1 (read-only, NAND.md) stays the default and the fallback.

## Gate status

| Gate | Status |
|---|---|
| Validation step 1, layout (criteria **G1-G4**) | **PASSED** 2026-10-08, see below |
| G5 backup | taken 2026-10-08 by the orchestrator (`~/oe-tool/backup/nand-raw-20261008`, raw + corrected, `SHA256SUMS`) |
| G5 restore | procedure + tool done (`nand/RESTORE.md`), **PASSED in simulation** (bit-exact); never run on the box |
| G6 rehearsal | **PASSED in simulation** 2026-10-08: 32/32 gates (`nand/rehearsal/results-20261008.txt`) |
| G7 sacrificial volume | scripts ready (`nand/phase2/`), rehearsed in simulation; to run on the box next |
| G8, G9 | not started |

## Implementation (2026-10-08)

Kernel (`patches/linux/`, applied by Buildroot to every image; inert unless
switched on):

| Patch | What |
|---|---|
| 0001 | brcmnand refuses program/erase unless `brcmnand.allow_write=1` (phase 1) |
| 0002 | MTD write fence gate: a chip with `fence_writes` (brcmnand, nandsim) programs, erases or marks bad only when `mtd_fence_check()` passes, i.e. the registered fence vouches for the calling task and range; nothing registered = refused. Checked in the NAND core (`nand_do_write_ops`, `nand_do_write_oob`, `nand_erase_nand`, `nand_block_markbad_lowlevel`), so BBT updates are covered |
| 0003 | brcmnand: `allow_write` becomes runtime (0644), the chip is always fenced |
| 0004 | UBI write fence `ubi.fence=<volumes>` (runtime, for devices attached afterwards): free and fenced-volume PEBs only; all other PEBs (and attach erase candidates not owned by a fenced volume) in a `fence_off` tree, never moved, scrubbed or erased; LEB write/unmap/atomic change only on fenced volumes, so no volume-table change; bad-block marking refused; fastmap must be off; all writes refused until set up; each program/erase registered in flight for the MTD gate; rate-limited log of every write/erase with PEB and owner; `debugfs ubi/ubiN/fence` (state, PEB counts, writes, erases, refused, scrub_refused, gate counters); `debugfs ubi/fence_restore` (raw restore of listed PEBs, only with no UBI device on the chip) |

So a NAND write needs, all at once: an image built with `NAND=rw-jffs`
(the `image` partition writable in the DT; `loader` always read-only),
`brcmnand.allow_write=1`, and either fenced UBI I/O on a fenced volume or an
explicit restore entry with UBI detached.

OS (`gt-be98-os`): `/etc/conf.d/gt-be98-jffs` `JFFS_MODE=ro` (default) |
`rw` with `FENCE_VOLUMES` (default `jffs2`; `mltest` for G7). In `rw` mode
the service sets the fence, attaches, checks `debugfs` (state active, the
volumes covered, not read-only), only then sets `allow_write=1`, mounts `/jffs`
read-only, applies the saved state and remounts read-write; any failure falls
back to the phase-1 read-only state (`lock_down`). `gt-be98-save --local`
writes `/jffs/mainline-os/state.tgz` directly (previous kept as `.prev`).

Tools (`nand/build-phase2-kit.sh` -> `$OUT/images/nand-phase2-kit/`, static,
not in the rootfs): `gt-be98-nandrestore`, `gt-be98-ubileb` (LEB writes with
the atomic-change ioctl: no volume-table update), `gt-be98-nandtool`,
`nanddump`, the G7 scripts and patterns.

### G6 / G5-restore rehearsal (simulation) PASSED - 2026-10-08

`nand/rehearsal/run.sh`: QEMU virt, the patched kernel with nandsim shaped
like the box's NAND (Macronix ID c2 da 90 95: 256 MiB, 128 KiB blocks, 2 KiB
pages; partitions loader 16 / image 2024 / rest 8 blocks), loaded with the
corrected page data of the box's backup; UBI attached with the box's VID
header offset (2048). Differences from the box, stated: nandsim has 64 B of
OOB with software BCH-8 (the box: 108 B controller layout, hardware BCH-8),
allows sub-page writes (UBI writes 512-B units there), and the rehearsal
kernel has a UBI wear-leveling threshold of 128 instead of 4096 so that
wear-leveling actually runs. The fence logic and the UBI/UBIFS behaviour are
the same; the brcmnand write path itself is exercised only on the box (G7).

Results (32/32 gates, `nand/rehearsal/results-20261008.txt`):

- data loaded bit-identical; a 6-bit flip injected in a bootfs2 PEB still
  corrects (and reads return "6 corrected");
- chip fenced, nothing registered: raw erase, raw write and bad-block marking
  refused, the PEB unchanged; an unfenced UBI attach cannot write (its
  wear-leveling write is refused at the gate, UBI goes read-only) and cannot
  create a volume;
- fence on jffs2: active, 407 fenced / 702 free / 915 fenced-off PEBs; volume
  create and remove refused, writes to rootfs2 refused, raw writes refused,
  restore refused while attached; bootfs2 reads the stock sha256 and its
  6-bit-flip PEB's scrub request is refused (data readable, PEB untouched);
- 300 x 1 MiB write+sync+delete on UBIFS jffs2: 170,392 fenced writes and
  3,263 erases (wear-leveling moves included), 60 rate-limited log lines, the
  marker file kept;
- after detach: 108 PEBs changed: 37 jffs2 + 71 free, **0 other**; loader
  unchanged; volume table unchanged; bootfs2 still the stock sha256;
  metadata1/2 unchanged; jffs2 mounts with the marker;
- restore: the 108 differing PEBs rewritten and verified, the whole partition
  bit-exact to the pre-session raw dump, restore entries cleared;
- G7 rehearsal: after a stock-style `ubimkvol mltest`, fence=mltest writes and
  reads back 4 LEBs, a jffs2 write is refused, only 4 free PEBs changed.

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

## Next on the box (in order, each gated by the previous)

1. G7: a `NAND=rw-jffs` image; on stock `stock-mltest.sh create`; on
   mainline `JFFS_MODE=rw FENCE_VOLUMES=mltest`, `mltest-mainline.sh write-a`;
   on stock `stock-mltest.sh verify-a` and `write-b`; on mainline
   `mltest-mainline.sh verify-b`; on stock `stock-mltest.sh remove`;
   `stock-nandinfo.sh` before/after (only mltest and free PEBs, static
   volume sha256s unchanged).
2. G8: fresh raw dump, then one supervised `FENCE_VOLUMES=jffs2` session
   (`gt-be98-save --local`), then a stock boot and `stock-nandinfo.sh`.
3. G9: restore rehearsal on the box only if the owner wants it (RESTORE.md).

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

# iDMA64 host-cap gate — RE findings (BCM6726b0 / dhd.ko vs open brcmfmac)

Status: **the original "single missing hcap1 OR-bit" hypothesis is NOT confirmed.**
The static evidence says iDMA is gated by a **multi-part host-side state**, not by one
bit dhd ORs into the published hcap1 word. The most actionable single candidate is in
**hcap2** (we publish hcap2 = 0), but the dongle's "Host does not support iDMA" is driven
by the per-HME-user descriptor flag path, which our driver never populates. Read the
"Verdict" + "Falsification" sections before acting.

## Binaries / addressing
- `dhd.ko` aarch64, NOT stripped. Ghidra base 0x100000. r2 view base 0x08000000.
  Mapping: `Ghidra_addr = (r2_addr - 0x08000000) - 0x40 + 0x100000` (a 0x40 ELF-header
  skew; verified: writeshared r2 0x080505f0 == Ghidra 0x1505b0; readshared r2 0x08050b30
  == Ghidra 0x150af0).
- `ram.elf` is the 6726b0 firmware (ARM Thumb, stripped). It is the **consumer** that
  prints `Host does not support iDMA` / `Link iDMA failure` and dumps
  `flags %08x dcap1 %08x dcap2 %08x hcap1 %08x hcap2 %08x`. Its host-cap bit-test could
  not be read statically: the format strings are loaded via computed (base+offset)
  pointers, so neither r2 nor Ghidra resolves the xref to the gate function. This is the
  one piece of ground truth that remains unread.

## Key finding 1 — host iDMA is gated by a bus byte, set from the DONGLE rev, not a hcap OR
`dhdpcie_bus_read_pcie_ipc` (Ghidra 0x14b450). `uVar20 = dcap_word & 0xff` is the
dongle's IPC capability **rev**; dhd compares it against the literal **0x8b** (its
supported rev, printed as `expected 0x8b got %u`). Branch:
```
if (uVar20 <  0x8b) { *(bus+0x3c) = 0x10; }                 // iDMA16 descriptor stride
else                { *(bus+0x3c) = 0x20;                    // iDMA64 descriptor stride
                      *(undefined1*)((long)bus+0x34a1) = 1; }// HOST iDMA64-ENABLE flag
...
if (0x87 < uVar20 && ((uint)dcap2[0x15] >> 4 & 1)) *(si+0x30c2) = 1;  // HWA gate
```
So `bus+0x34a1` ("host will run iDMA64") is set **only when the dongle advertises rev
>= 0x8b**. Our open driver publishes hcap1 low byte = **0x8b**, i.e. it already hits the
rev threshold — the rev is NOT the missing piece.

## Key finding 2 — the per-HME-user iDMA flag is bit6 of the HME-user halfword
`dhd_prot_hme_init` (Ghidra 0x140db0) walks HME users. For each user at `hme+0x10`, the
flags halfword is at `+4`:
```
if ((*(ushort*)(hme_user+4) >> 6 & 1) && *(char*)(prot+0x34a1)) {   // bit6 == iDMA user
    base = *(long*)(prot+0x3468);                                    // iDMA window base
    off  = *(uint*)(hme_user+0x10);
    desc->haddr_lo = off + *(int*)(prot+0x3470);                     // translate via iDMA win
    desc->haddr_hi = *(int*)(prot+0x3474);
    desc->len      = *(ushort*)(hme_user+6) << 12;
}                                                                    // else: plain DMA buf
```
`dhdpcie_bus_read_pcie_ipc` independently sets a dongle-side flag when **any** HME user
has bit6: `if ((hme_user[+0x14] >> 6 & 1)) *(bus+0x694) = 1;`.
Live capture: "only 1 of 23 HME users has the iDMA gate bit7 set" — note our gate field
is **bit6** (0x40) in this build, distinct from bit7 (0x80, segmented/page flag, tested at
`(*(ushort*)(hme_user+4) >> 7 & 1)` in the same loop). Confirm which bit our 23 users use.

## Key finding 3 — HWA caps live in a different word (NOT iDMA)
`dhd_prot_set_hwa_attributes` (Ghidra 0x146770) reads prot+0x6f4 (hwa caps word):
bit24 (0x1000000)=HWA-RxPost→sets ring flag bit0; bit25 (0x2000000)=HWA-TxCpl→ring bit1;
bit26 (0x4000000)=HWA-RxCpl→per-ring bit2 (`| 4`). These are HWA, not iDMA. Do not
confuse with the iDMA path.

## Our hcap1 = 0x1019008b decode (bits 0,1,3,7,16,19,20,28)
low byte 0x8b = IPC rev (matches dhd's expected 0x8b). bit16 (0x10000)=DMA_INDEX,
bit20 (0x100000)=2BYTE_INDEX, bit28 (0x10000000)=HME, bit19 (0x80000) unaccounted
(HOSTRDY group). hcap2 = 0x00000000 — **we advertise nothing in the second host-cap word.**

## `idma64` is a DONGLE nvram knob, not a dhd module param
Strings `idma64:X` / `idma64:1` / `idma64:0` (file 0xba158-0xba178) are nvram-template
writes pushed to the dongle; `idma64` is NOT in `.modinfo` (no `parmtype=idma64`). So there
is no host-side `idma64` module-param OR-mask to copy. The host/dongle iDMA negotiation is
driven by the IPC rev + HME-user flags above, plus whatever bit hcap2 carries.

## VERDICT
There is **no single `OR 0x____ into hcap1`** that turns iDMA on; the original premise is
falsified by `dhdpcie_bus_read_pcie_ipc` (iDMA enable = dongle-rev gate on `bus+0x34a1`,
which we already satisfy with rev 0x8b) and by `dhd_prot_hme_init` (iDMA is realized
per-HME-user via flag **bit6 (0x40)** of the user halfword at `hme_user+4`, plus the iDMA
address-window registers at `prot+0x3468/0x3470/0x3474`).

To make the dongle stop printing "Host does not support iDMA", the open driver must:
1. Set HME-user descriptor flag **bit6 (0x40)** on the iDMA-eligible user(s) — this is what
   the dongle scans (`hme_user[+0x14] >> 6`) to decide the host supports iDMA. Today only
   ~1/23 users carry it; dhd sets it on all iDMA users.
2. Populate the iDMA window triple `prot+0x3468 (base lo) / +0x3470 (off) / +0x3474 (hi)`
   and the host-enable byte `bus+0x34a1`, so HME-user addresses are emitted through the
   iDMA aperture.
3. The single most likely missing **published** bit is in **hcap2** (we send 0). Candidate:
   the iDMA-feature advertisement bit the firmware reads from hcap2 — UNREAD (see below).

## CONFIDENCE
Medium. High confidence on findings 1-3 (clean decompiles of named, unstripped dhd
functions, cited above). Low-to-medium confidence that the fix reduces to a hcap2 bit:
the exact firmware-side bit-test in `ram.elf` (`Host does not support iDMA`) could not be
read because its string xref is unresolved by static tools (base+offset string loads).

## FALSIFICATION / next step to close it
- Definitive test: instrument or single-step the firmware's hcap consumer (the function
  that prints `HME dcap %u hcap %u host_mem len` @ ram.elf vaddr 0x760a1 and
  `Host does not support iDMA` @ 0x78c65) to see which word/bit it AND-masks. Use the QEMU
  dhd harness or a JTAG/console dump of hcap1+hcap2 at the moment of the failure, then diff
  dhd's published hcap2 vs ours (ours=0).
- If a live dhd boot on the same silicon shows hcap2 != 0, the set bits there ARE the
  missing advertisement — OR exactly those into our hcap2. If dhd's hcap2 is also 0, then
  iDMA is purely the HME-user-bit6 + iDMA-window path (findings 1-2) and hcap is a red
  herring — fix the HME user flags instead.

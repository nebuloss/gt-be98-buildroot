# CP-2b — BAR gate CLEARED, dhd driven into si_attach + EROM enumeration

Follow-on to `cp2-rdpa_gpl-rootcause-and-dhd-probe.md`. That note left the real
`dhd.ko` probe stuck in the PCI BAR/accessibility stage
(`dhdpcie_init: device not accessible`). This note records how that gate was
**root-caused from the dhd.ko disasm**, the device-model fix, and how far dhd
then advanced: **past BAR enumeration, into `si_attach` → chipid recognition →
`ai_scan` EROM walk.** All QEMU `-M virt` only; no device, no flash.

Artifacts:
- extended device-model: `qemu-harness/device-model/broadcom-fmac-stub.c`
- run trace: `qemu-harness/traces/cp2-dhd-si_attach-erom.log`
- disasm working set: `job-tmp/cp2-dis/*.s` (not committed; regenerate with objdump)

---

## 1. The "device not accessible" gate — ROOT CAUSE (was the prior frontier)

The prior CP-2 note guessed the gate was "cfg 0x6c must be nonzero (liveness)".
**That was wrong.** Disasm of `dhdpcie_prepare_pcie_ep` (dhd.ko @0x4ddf0,
called from `dhdpcie_pci_probe+0x1f4` with arg2 = 1) shows the real gate:

```
prepare_pcie_ep(osh, pdev, mode=1):
  w23 = pdev->subsystem_device        ; struct pci_dev +62
  cfg 0x00 -> must be vendor 0x14e4
  cfg 0x110 -> w21 (VSEC scratch; written back at end iff nonzero)
  ; mode==1 path branches on subsystem-device-id:
  if ((subsys_devid - 0x6024) & 0xffff) <= 0xd     ; window 0x6024..0x6031
        -> recognized 6717/6726-class part
  cfg 0x6c -> w0
  tst w0, #0xf0
  b.eq  -> return -40 (-EINVAL)        ; <-- THE GATE
```

So two independent conditions, both **[RE-CONFIRMED from disasm]**:
1. `pdev->subsystem_device` (cfg 0x2e) must land in **0x6024..0x6031**.
   GT-BE98 nvram advertises `1:devid=0x602d` — in range. The prior model left
   the subsystem id at QEMU's default (`0x1100`), so the recognized path was not
   even taken.
2. cfg `0x6c` must satisfy **`(val & 0xF0) != 0`** — i.e. bits[7:4] set, *not*
   merely "nonzero". The prior model stamped `0x00000001`, which fails
   `tst #0xf0`. This 0x6c sits at Express-cap+0x28 (DevCtl2/DevSta2 region); the
   0xF0 nibble is a vendor liveness/gen field dhd polls.

**Fix (device-model only):** set `cfg[0x2e]=0x602d` (sub-vendor 0x14e4),
`cfg[0x6c]=0x000000f0` (write-masked so it persists), and zero `cfg[0x110]` to a
defined value. No closed binary touched.

After the fix dhd cleared the gate, ran the **backplane reset** path
(`dhdpcie_prepare_pcie_ep: Resettting backplane for device 0x6717`, then polled
cfg 0x88 bit 0x400 for "SB reset de-asserted"), passed
`dhdpcie_scan_resource`/`dhdpcie_get_resource` (logging only a benign
`BAR2 Not enabled … size(0)` note — the warning did not abort), and entered
`dhdpcie_dongle_attach → si_attach`.

## 2. si_attach / chipid — RECOGNIZED

`si_attach → si_doattach.constprop.0` (dhd.ko @0x701b0):
- calls `si_enum_base_pa(devid=0x602d)` → returns backplane enum base
  **0x28000000** (RE-CONFIRMED: `si_enum_base_pa` @0x6f960 + the live window the
  driver programmed). The prior model hard-coded the legacy SB base 0x18000000,
  so the chipid read returned 0 ("unmodeled") and si_attach failed *here*.
- programs the BAR0 sliding window (cfg 0x80) to 0x28000000 and reads **offset 0
  = ChipCommon chipid register**.
- chipid decode (RE-CONFIRMED @0x702dc-0x70338):
  `[15:0]=id  [19:16]=rev  [23:20]=pkg  [27:24]=#cores  [31:28]=chiptype`.
  **chiptype must == 1 (SOCI_AI)** for dhd to run `ai_scan` (the AXI/EROM walk).

**Device-model:** serve chipid at backplane 0x28000000 →
`0x16006717` (id 0x6717, rev 0, **chiptype=AI**). dhd accepted it and proceeded
to `ai_scan`. (Note: the exact id-normalization branch at 0x70328 expects 0x6716
or the 0xaac9/0xaad2→0x6717 path; chiptype=AI is the gate that drove ai_scan, so
the literal id value was not fatal here.)

## 3. ai_scan / EROM — WALKING (new frontier)

dhd's `ai_scan` (@0x616c0) read ChipCommon **eromptr** (chipc offset 0xfc) → the
model returns `0x28010000`, then re-pointed the window there and walked the
synthetic EROM via `get_erom_ent` (@0x611e0). **RE-CONFIRMED AI/DMP EROM grammar:**

```
CIA (Component-ID A): [0]=valid [3:1]=tag(CI=0) [19:8]=cid [31:20]=mfg(=0x43b BCM)
CIB (Component-ID B): [8:4]=#ASD  [13:9]=nmw  [18:14]=nsw  [23:19]=nmp
                      (ai_scan SKIPS the core if nmw==0, @0x617ac)
ASD (Addr-Space Desc): [0]=valid [2:1]=tag(ADDR=2) [3]=is64 [5:4]=sztype
                       [7:6]=addrtype [11:8]=slave-port [31:12]=base>>12
                       (get_asd @0x61590; sztype 0x3 => explicit size word)
END terminator = 0x0000000F
```

Live trace (model EROM = ChipCommon CIA + CIB + one 8K ASD + END):
```
BAR0 read CHIPID  bp=0x28000000 -> 0x16006717  (id=0x6717 rev=0 type=AI)
BAR0 read EROMPTR bp=0x280000fc -> 0x28010000
BAR0 read EROM[0] bp=0x28010000 -> 0x43b80001   (CIA: mfg 0x43b, cid 0x800 ChipCommon)
BAR0 read EROM[1] bp=0x28010004 -> 0x00000211   (CIB: nmw=1, #ASD=1, valid)
BAR0 read EROM[2] bp=0x28010008 -> 0x28000015   (ASD: base 0x28000000, sztype1)
BAR0 read EROM[3] bp=0x2801000c -> 0x0000000F   (END)
dhdpcie_dongle_attach: si_attach failed!
```

So ai_scan **parsed exactly one core (ChipCommon) and hit END.** si_doattach
then returned NULL → `si_attach failed`.

## 4. The honest frontier — multi-core EROM

dhd is now blocked **inside `si_doattach`, after `ai_scan` returns**, because the
EROM enumerates only ChipCommon. `si_doattach` (and the subsequent
`dhdpcie_dongle_attach`) require the **PCIe2 buscore** (to wire up the doorbell /
ring registers) and, for firmware download + RAM sizing, the **ARM Cortex-A7
core** and **SYS_MEM core** (SPEC §1 — ramsize via `BCMA_CORE_SYS_MEM`). A
single-ChipCommon EROM cannot satisfy the buscore lookup.

**Next step (well-defined, mechanical):** extend `bcm_erom_table` to a full
multi-core EROM:
- ChipCommon (cid 0x800) — done,
- PCIe2 Gen2 host/dev core (the dhd "buscore"),
- ARM Cortex-A7 (`BCMA_CORE_ARM_CA7`),
- SYS_MEM (for ramsize),
each with correct CIA/CIB/ASD descriptors at their backplane addresses, plus the
per-core register windows the model must then answer (core control/status,
`si_setcoreidx` reads at +0x408/+0x800 region seen in `_ai_core_reset`). Once
si_doattach finds the buscore, dhd advances to `dhdpcie_dongle_attach` body →
`dhd_bus_download_firmware` (membytes into TCM) → CA7 release → **`read_pcie_ipc`**.

Only at `read_pcie_ipc` do the SPEC §2/§3/§4/§6/§7/§9 `[DYN]` fields become
RE-confirmable from a live dhd, and only then is **M3 (HME/MLO entanglement)**
empirically assessable.

## 5. M3 go/no-go — still UNDETERMINED (per the HALT mandate)

dhd has not reached the IPC/HME/ring stage; it stops in chip enumeration, well
upstream of `read_pcie_ipc`. So the decisive M3 question — *is a WI64-only open
back-end portable, or are HME/MLO entangled into the core ring/handshake?* —
**cannot yet be answered empirically.** What CP-2b establishes:

- The path from "device not accessible" all the way to **chip/EROM
  enumeration** is now mechanically open and the gates are *individually
  RE-confirmed*, not guessed: each was a specific, documented device-model field
  (subsys-devid window, cfg-0x6c 0xF0 nibble, enum base 0x28000000, chiptype=AI,
  the EROM grammar). None was a structural wall.
- No evidence of HME/MLO involvement this early — entirely consistent with the
  SPEC: HME/MLO live behind the post-`read_pcie_ipc` ring setup, which is still
  two iterations away (multi-core EROM → fw-download/CA7 → IPC).

The M3 verdict therefore remains **deferred, leaning still-testable**: the
remaining work to reach it is bounded device-model fidelity (the multi-core EROM
+ per-core register stubs + the membytes/CA7 plumbing), not a new unknown.
HALT here per the M3 mandate — do NOT build the WI64/HME/MLO back-end.

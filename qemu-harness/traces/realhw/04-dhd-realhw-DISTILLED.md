# Real-hardware dhd probe capture — DISTILLED (2026-06-09)

Device: GT-BE98 (4x BCM6726b0), committed v34 slot1. dhd.ko v17.10.369.39012.
Method: rmmod wl (SSH-survived, wired br0); insmod dhd with high debug; a
dmesg-poll-to-/jffs drainer (50ms, sync each pass) captured 203 lines BEFORE the
kernel hard-hung on the firmware-download DMA. Watchdog auto-reset to v34.
Raw: 03-dhd-probe-realhw-kmsg.log (203 lines). QEMU CP-2 died WAY earlier
(`dhdpcie_init: device not accessible` at PCI enum) — real HW blew past that.

## Real silicon facts (vs SPEC guesses)

| SPEC item | SPEC tag was | REAL HARDWARE | New tag |
|---|---|---|---|
| PCI config-space devid | n/a (QEMU used 0x6717; nvram devid 0x602d "informational") | **0x6716** (`PCI_PROBE ... device 6716`, `Resettting backplane for device 0x6716`) | RE-CONFIRMED |
| Chip on this unit | 6717a0 OR 6726b0 | **4x 6726b0** (wl revinfo chipnum 0x6726 chiprev 1; dhd resolves 6726b0/release/rtecdc.bin) | RE-CONFIRMED |
| CA7 dongle RAM size (§1 [DYN]) | unknown | **0x480000 = 4,718,592 B** (`dongle ram size is set to 4718592`; `Adjust dongle RAMSIZE to 0x480000`) | RE-CONFIRMED |
| Backplane/CA7 bring-up (§1 [DYN]) | "set_active exists, unverified" | real seq: `dhdpcie_prepare_pcie_ep: Resettting backplane for device 0x6716` -> `Polling for SB Reset state (PCI_SPROM_CONTROL)` -> `SB reset bit de-asserted by HW. Wait 2ms for Backplane RESET` | RE-CONFIRMED (sequence) |
| BAR phys addrs | QEMU synthetic | reg space (BAR0) @ **0xc1800000**, bar1 (TCM) @ **0xc1000000** (`dhdpcie_get_resource`) | RE-CONFIRMED (this unit) |
| PCIe link gen / MPS/MRR | unknown | **GEN2**, MPS 512, MRR 1024, devctl 0x123d50 | RE-CONFIRMED |
| Common ring item sizes (§5) | SDK: CTRL_SUB 40, CTRL_CMPLT 24 | **h2dctrl size 40 / d2hctrl size 24**, both max_items 512, **type 0 (WI64)** | RE-CONFIRMED |
| WI64 vs ACWI/CWI (§5 [DYN] "does FW honor WI64?") | DYN | runner negotiates **type 0 = WI64** for both control rings; runner ring-format caps `TxP 0x5 RxP 0x3 TxC 0x3 RxC 0x3` (these are the runner-offload formats, NOT the host-path WI; host control rings are plain WI64). WI64 IS in use. | RE-CONFIRMED (control rings) |
| HME (§6 "mandatory") | SDK/RE | **present + allocated**: `dhd_prot_host_mem_alloc: Alloc Legacy Host Memory DMA Buffer len 1314816`; `dhdpcie_bhm_mem_alloc: PCIe IPC BHM ALLOC SUCCESS: size 26MB ... len 27262976` @ pa lo 0x62d00000 | RE-CONFIRMED (alloc; bind not reached) |
| MLO IPC (§11 "deferrable") | RE-CONFIRMED (strings) | **runs at init even for single unit**: `dhd_mlo_ipc_init: ENTER ap_unit[0] mlo_unit[-1]` (mlo_unit=-1 => this unit not bound into an MLD; init still executes) | RE-CONFIRMED (init path) |
| FW container probe order (§8) | LFOC | dhd first tries `.bea` header: `dhd_bea_read_header: Not a .bea header` then proceeds (LFOC path) | RE-CONFIRMED (probe order) |
| fw/nvram path derivation (§8e) | RE-CONFIRMED | confirmed live: fw_path `/etc/wlan/dhd` + auto chip-subdir -> `/etc/wlan/dhd/6726b0/release/rtecdc.bin`; nvram path passed as **(null)** at insmod => dhd resolves model nvram (GT-BE98) internally, not via nvram_path= | RE-CONFIRMED |

## The hang (critical, reproducible 3x)

dhd progresses cleanly through: backplane reset -> scan_resource SUCCESS ->
dongle_attach SUCCESS -> GEN2 link -> dhd_attach -> runner ring attach (h2d/d2h
control, WI64) -> HME/BHM alloc -> MSI irq 76 -> dhd_bus_start_try -> resolves
6726b0/release/rtecdc.bin -> ramsize_adj 0x480000 -> **then HARD HANGS** at the
actual firmware membytes-DMA download into dongle RAM. No further printk ever
drains (the dmesg-poll drainer kthread stops being scheduled => a hard bus/AXI
hang, not a soft oops). The watchdog then resets to committed v34.

ROOT CAUSE (assessed): after `dhdpcie_prepare_pcie_ep` resets the dongle
backplane, the firmware-download DMA wedges the PCIe/AXI fabric on this live
silicon. The merlin `bcm_pcie_hcd` RC driver + runner/rdpa stack remain resident
and had already brought these 4 links up for wl with their own window/DMA
context; dhd re-driving the same EP (backplane reset + membytes DMA) collides at
the hardware-fabric level and hangs the whole SoC. This is NOT reachable/modelable
in QEMU (which dies at PCI-enum, far upstream).

## NOTE
- `rmmod wl` cleanly released all 4 EPs (driver= empty) and SSH survived over the
  wired br0 every time — the lifeline design held across all 3 hang+reset cycles.
- The first attempt (blocking `cat /proc/kmsg` + per-line sync) captured ZERO dhd
  lines: the hang preempted the logger kthread before its first drain. The
  dmesg-poll variant (rewrite whole buffer every 50ms + sync) is what caught the
  203 lines — the right technique for capturing up to a hard hang on this box.

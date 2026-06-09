# CP-1 — the disposable "harness kernel" (open-brcmfmac roadmap, M1)

This directory is **CP-1** of `docs/brcmfmac-bcm6717/ROADMAP.md`: the from-source
**disposable harness kernel** + the QEMU rig that unblocks all dynamic IPC capture
for the BCM6717/6726 FullMAC RE effort. It is RESEARCH-ONLY and **never flashed**.

## What CP-1 needed (from the ROADMAP)

The real `dhd.ko` cannot load on a stock kernel (276 merlin-only vmlinux symbols
missing). The merlin kernel that exports them **panics under `qemu -M virt`** in
SoC-fabric `postcore_initcall`s touching absent hardware. CP-1 = build a one-off
kernel from the merlin 4.19.294 source that:
- boots under a **generic** `qemu-system-aarch64 -M virt` (virtio + PCI_HOST_GENERIC),
- **stubs the SoC initcalls** that hang/fault without real hardware,
- **keeps the EXPORT_SYMBOLs** the closed dhd dep-chain needs (nbuff/blog/knvram +
  the SoC-fabric symbols), with vermagic + module-load ABI intact,
- has FTRACE/KPROBES/KGDB/DYNAMIC_DEBUG on for IPC capture.

## Result — DELIVERED (boots), real-dhd dep-chain load PARTIAL (blocked at rdpa_gpl)

The harness kernel **boots to PID1 under `-M virt`** and the closed dhd dep-chain
loads 7 modules deep before a deterministic blocker. See `../traces/`:
- `cp1-dhd-harness-distilled.txt` — the headline transcript.
- `dhd-harness.log` — full deduped boot+load console.
- `cp1-rdpa_gpl-resolve_symbol-fault.txt` — the minimal `bdmf → rdpa_gpl` isolation.

```
BCM UBUS Driver: QEMU-harness stub (SoC fabric init skipped)   <- stub 1
PMC driver:      QEMU-harness stub (PMC init skipped)           <- stub 2
XRDP:            QEMU-harness stub (power-on skipped)            <- stub 3 (+keyhole NOP)
9000000.pl011: ttyAMA0 ... is a PL011 rev1                      <- SoC init survived
Run /init as init process
  0000:00:02.0 vendor=0x14e4         <- the emulated Broadcom FullMAC PCIe device enumerated
finit_module bcm_knvram  -> OK
finit_module bcmlibs     -> OK   (benign module_put refcount WARNING)
finit_module bdmf        -> OK
finit_module bcmmcast    -> OK
finit_module cfg80211    -> OK   (X.509 regulatory certs loaded; needed FW_LOADER=y)
finit_module wlshared    -> OK
finit_module hnd         -> OK
finit_module rdpa_gpl    -> FAULT in resolve_symbol  <- the CP-1 blocker
```

### The blocker (precise)

`insmod rdpa_gpl.ko` faults the kernel in `resolve_symbol.constprop.0+0xcc`
(`load_module → finit_module`) at vaddr `0x0000000100000021`. Isolated to the
minimal case **bdmf loaded, then rdpa_gpl**: rdpa_gpl imports exactly one
inter-module symbol, `bdmf_global_trace_level` (from bdmf), + 7 vmlinux symbols
(printk, snprintf, strcmp, __stack_chk_guard/fail, of_irq_to_resource,
__platform_driver_register) — **all present** in the harness kernel. The fault is
`find_symbol` walking **bdmf's** `__ksymtab` and reading ~0x1d0 bytes *past* its
end, even though bdmf's ksymtab is self-consistent (152 entries, PREL32 8-byte,
`size/8 == relocs/2 == 152`, matching the harness kernel's
`CONFIG_HAVE_ARCH_PREL32_RELOCATIONS=y`). MODVERSIONS is OFF on both (no kcrctab),
so this is **not** a CRC/vermagic mismatch. It is a narrow closed-module-loader
interaction in `each_symbol_section` that needs KGDB single-step to root-cause —
beyond the CP-1 boot+probe deliverable. dhd.ko hard-depends on rdpa_gpl, so the
real dhd probe is gated behind this.

### How close to the prize

- The **harness kernel boots** under generic `-M virt` (the original UBUS panic +
  PMC + XRDP faults all fixed) — the primary CP-1 deliverable. ✅
- The **emulated Broadcom 14e4 PCIe device enumerates** and is visible to PID1. ✅
- **7/12 closed dhd deps load OK** (incl. cfg80211 once FW_LOADER was built in). ✅
- The **synthetic** dhd handshake (chipid → fw-download → shared-struct read →
  doorbell/MSI) was already captured end-to-end by `bcmfmac-probe` on the stock
  kernel (`../traces/handshake-distilled.txt`, committed `973277e`). ✅
- The **real** dhd probe is blocked one dep short of dhd.ko itself, by the
  rdpa_gpl resolve_symbol fault above. ⛔ (CP-2 prerequisite.)

## The stubs (all compile-time `#ifdef BCM_QEMU_HARNESS`, inert in a device build)

`0001-soc-initcall-stubs-for-qemu-virt-harness.patch` (apply at the src-rt root):
1. `bcm_ubus_dt.c` `bcm_ubus_drv_init` — early-return before `bcm_ubus_config()`
   (writes an absent UBUS-fabric register → the original `-M virt` panic).
2. `pmc_drv_dt.c` `bcm_pmc_drv_reg` — early-return before the DT scan + `pmc_init()`
   (NULL `g_pmc->pmc_base` deref → `pmc_initmode` fault).
3. `pmc_xrdp.c` `pmc_xrdp_init` — early-return before powering the XRDP/Runner PMB
   domain (`PowerOnDevice` → absent BPCM keyhole fault).
4. `pmc_drv.c` `read/write_bpcm_reg_direct_keyhole` — NOP under the harness, so
   **every** remaining PMC power-domain call (e.g. `pmc_wan_initcall`) is neutered
   at the source instead of stubbing each initcall.

The patch is applied via `KCFLAGS=-DBCM_QEMU_HARNESS`; with no `-D` (every normal
device/flash build) the guards vanish and the source is byte-for-byte upstream.

## Config (`config_harness`)

`config_gt-be98` (the device config) + a virt/debug fragment (last-wins):
`PCI_HOST_GENERIC`, `VIRTIO_{PCI,MMIO,BLK,CONSOLE,NET}`, `FW_LOADER=y` (cfg80211
needs `request_firmware`), `MODULE_FORCE_LOAD`, `FTRACE`/`KPROBES`/`KGDB`/
`DYNAMIC_DEBUG`. vermagic stays `4.19.294 SMP preempt mod_unload aarch64` (no
SUBLEVEL/SMP/PREEMPT/MOD_UNLOAD/MODVERSIONS change) so the dhd module-load ABI is
intact: of dhd's 276 needed vmlinux symbols, the harness vmlinux provides the 70
SoC-fabric ones (bcm_printk/blog/nbuff/gbpm/BcmHalMapInterrupt/…); the other 206
are inter-module exports resolved by loading the dep chain in order.

## Console note

The merlin `amba-pl011` runtime console (`ttyAMA0`) does not enable on `-M virt`
(its clock comes from the SoC init we stubbed), so only **earlycon** works. QEMU
prints "PL011 data written to disabled UART" per byte; `scripts/clean-earlycon-log.py`
reflows the raw capture into readable kernel log lines.

## Reproduce

```sh
# 1. build the harness kernel (~few min relink; writes Image here, restores baseline after)
qemu-harness/harness-kernel/build-harness-kernel.sh build
#    (applies the stub patch via KCFLAGS=-DBCM_QEMU_HARNESS; the SDK .c are NOT edited
#     persistently — see the patch file. Run `... restore` to revert .config/Image/vmlinux.)
# 2. build the dhd initramfs (static aarch64 init + dep chain + dhd.ko + cfg80211.ko)
qemu-harness/scripts/build-initramfs-dhd.sh
# 3. boot + capture
qemu-harness/scripts/run-harness-dhd.sh
#    GDB=1 ... also opens the gdbstub on :1234 (-s -S) for KGDB/resolve_symbol RE
```

Prereqs (paths in `../scripts/config.env`): the gcc-10.3 aarch64 cross toolchain,
the merlin `src-rt-5.04behnd.4916` source tree, QEMU 10.0.0 with the
`broadcom-fmac-stub` device-model built in (`../scripts/apply-to-qemu.sh`), and the
closed `dhd.ko` + deps + `cfg80211.ko`.

## Files

| File | What |
|---|---|
| `build-harness-kernel.sh` | builds the harness Image (stub patch via KCFLAGS) + `restore` |
| `0001-soc-initcall-stubs-for-qemu-virt-harness.patch` | the 4 SoC-initcall stubs (apply at src-rt root) |
| `config_harness` | device config + virt/debug overrides |
| `Image` | the built harness kernel (committed; 4.19.294 aarch64, vermagic-preserved) |

## Next (CP-2, after the rdpa_gpl loader fault is cleared)

Root-cause the `resolve_symbol` walk-off-end via KGDB (`GDB=1`), or force-resolve
`bdmf_global_trace_level` so rdpa_gpl/wfd/dhd load; then enable dhd `dyndbg` and let
the **real** dhd drive the tunable device-model to capture the true `pcie_ipc_t` /
ring layout (ROADMAP §4 table). HALT before M3/M4 per the ROADMAP.

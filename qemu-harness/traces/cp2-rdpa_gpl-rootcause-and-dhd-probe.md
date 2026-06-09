# CP-2 — rdpa_gpl loader-fault ROOT CAUSE + fix, and the real dhd probe frontier

This is the CP-2 follow-on to `cp1-rdpa_gpl-resolve_symbol-fault.txt`. It (1) root-causes
the `resolve_symbol` fault that blocked the dhd dep-chain at `rdpa_gpl`, (2) records the
least-invasive fix, and (3) documents how far the **real `dhd.ko` probe** then progressed
against the emulated device, with the next blocker precisely located.

All work is QEMU `-M virt` only. No real device, no flash.

---

## 1. The CP-1 blocker — ROOT CAUSE (captured live via gdb)

**Symptom (CP-1):** `insmod rdpa_gpl.ko` faulted the kernel in
`resolve_symbol.constprop.0+0xcc` at vaddr `0x100000021`, with `x1=0x0000000100000001`.
The faulting instruction is `ldr x3, [x1, #32]`.

**What +0xcc actually is.** Disassembly of the harness `vmlinux` shows `resolve_symbol+0xb0..+0xd4`
is `already_uses()` inlined into `ref_module()` (Broadcom's `module.c` calls `ref_module`
after a successful `find_symbol`). It walks `owner->source_list` (a `list_head` at
`struct module + 0x2f8`):

```
+0xac  ldr   x1, [x23, #760]      ; x1 = owner->source_list.next   (760 = 0x2f8)
+0xb0  add   x24, x23, #0x2f8     ; x24 = &owner->source_list  (list head, loop sentinel)
+0xc0  ldr   x1, [x1]            ; x1 = next->next
+0xcc  ldr   x3, [x1, #32]       ; x3 = container_of(...)->source  (module_use.source @+32)  <-- FAULT
```

So the fault is **`already_uses(rdpa_gpl, bdmf)` walking bdmf's `source_list`, whose
`.next` was corrupt** (`0x100000001`, i.e. two packed 32-bit `1`s — not a kernel pointer,
not an `INIT_LIST_HEAD` self-pointer). It is NOT a ksymtab/PREL32/CRC problem; bdmf's
ksymtab is fine. The earlier "walks 0x1d0 past ksymtab end" hypothesis was wrong.

**gdb ground truth.** With `nokaslr`, breaking at `do_init_module(bdmf)`:
- right after bdmf loads, `bdmf->source_list = {next=&source_list, prev=&source_list}` — **pristine**.
- a hardware watchpoint on `&bdmf->source_list` then fired during bdmf's OWN init at
  `kobject_init+76` (`stp xzr,xzr,[x19,#64]`), called from `cdev_init`, called from bdmf's
  `init_module` at bdmf+0x153c (== `bdmf_chrdev_init`'s `cdev_init(&bdmf_chrdev_cdev, …)`).
  The `cdev`/`kobject` being initialized sat at `bdmf_struct_module + 0x2c0`, i.e. it
  **overlapped bdmf's own `struct module`** and clobbered `source_list` (+0x2f8) with the
  kobject's `{1,1,0}`.

**Why the overlap.** `struct module` size mismatch:
- `bdmf.ko`'s `.gnu.linkonce.this_module` section = **0x280** bytes (= `sizeof(struct module)`
  in the DEVICE config, which has FTRACE/TRACING/TRACEPOINTS **off**).
- the harness `vmlinux` had `CONFIG_FUNCTION_TRACER=y` (added "for IPC capture"), which selects
  `TRACEPOINTS`/`TRACING`/`EVENT_TRACING`/`FTRACE_MCOUNT_RECORD`. Those insert
  `num_tracepoints / tracepoints_ptrs / num_trace_bprintk_fmt / trace_bprintk_fmt_start /
  trace_events / … / num_ftrace_callsites / ftrace_callsites` **before** `source_list`,
  growing `sizeof(struct module)` to **0x340** (+0xC0) and moving `source_list` from 0x220
  to 0x2f8.

The module loader treats each `.ko`'s `.gnu.linkonce.this_module` (0x280) as the `struct module`
and lays the module's `.bss` immediately after it. The running kernel then reads/writes 0x340
bytes of struct-module fields into that 0x280 slot — the extra 0xC0 bytes (incl. `source_list`
@0x2f8) land **inside bdmf's `.bss`**, where `bdmf_chrdev_cdev` lives. bdmf's own
`cdev_init()` writes the cdev → corrupts the kernel-owned `source_list`. The next module
(`rdpa_gpl`) resolving `bdmf_global_trace_level` walks the corrupt list and faults.

**FIX (least-invasive, harness-only).** Disable the FTRACE family in
`qemu-harness/harness-kernel/config_harness` so `struct module` stays byte-identical to the
device layout (0x280, `source_list` @0x220):
`# CONFIG_FTRACE / FUNCTION_TRACER / DYNAMIC_FTRACE / TRACEPOINTS / TRACING /
EVENT_TRACING / FTRACE_MCOUNT_RECORD / KPROBE_EVENTS is not set`. KGDB + plain KPROBES +
DYNAMIC_DEBUG are kept (none add struct-module fields) — they give all the capture
instrumentation needed. Verified post-rebuild: harness `vmlinux` `sizeof(struct module)=0x280`,
`source_list` @0x220.

(Also: the build script's `yes "" | make syncconfig` was replaced with non-interactive
`make olddefconfig </dev/null` to dodge the SIGPIPE-under-pipefail stall the CP-1 CAVEAT warned of.)

**Result after the fix:** the full dep chain loads, no fault:
`bcm_knvram, bcmlibs, bdmf, bcmmcast, cfg80211, wlshared, hnd, rdpa_gpl(OK), emf, igs, wfd,
bcm_enet` — then `dhd.ko` (see §3).

---

## 2. Second blocker — bcm_pcie_hcd init hang (and its fix)

With the loader fixed, `bcm_pcie_hcd.ko` finit_module **hung**: gdb interrupt showed it spinning
in `__const_udelay` (frame in bcm_pcie_hcd init_layout) — its probe/`bcm963xx_hc_core_reset` /
`bcm963xx_hc_is_pcie_link_up` polls for a Broadcom PCIe **root-complex** link that does not
exist under `-M virt` (the emulated 14e4 device is on the generic PCIe host bridge, not the
Broadcom RC).

dhd imports exactly two symbols from bcm_pcie_hcd — `bcm_pcie_map_bar_addr` /
`bcm_pcie_config_bar_addr` — and both are used **only** on the Runner-offload path
(`dhd_runner.c`), which is disabled. Fix: a tiny GPL **shim** module
(`cp2-shim/bcm_pcie_hcd_shim.c`, packed as `bcm_pcie_hcd_shim.ko`) that exports those two as
no-op stubs and is loaded **instead of** the real bcm_pcie_hcd. No closed module is modified.

---

## 3. The REAL dhd probe — how far it got (CP-2 prize partial)

With (1)+(2), the closed `dhd.ko` LOADS and its **real probe runs against the emulated device**:

```
dhd_module_init in
PCI_PROBE:  bus 0, slot 2, vendor 14E4, device 6717 (good PCI location)   <- dhd matched our device
dhdpcie_init: device not accessible
dhdpcie_pci_probe: PCIe Enumeration failed
dhd_module_init: Failed to load driver max retry reached
==== harness done; powering off ====     (no kernel panic; clean ret/ poweroff)
```

dhd's `dhdpcie_pci_probe` call order (disasm of dhd.ko):
`dhdpcie_chipmatch (OK) → osl_attach → osl_static_mem_init → dhdpcie_prepare_pcie_ep →
dhdpcie_scan_resource → (only on success) dhdpcie_bus_attach → dhdpcie_dongle_attach → si_attach`.

**Where it stops (located by gdb breakpoints at dhd_base + symbol offsets, none past this point hit):**
- `dhdpcie_prepare_pcie_ep` runs: reads cfg `0x00` (vendor=0x14e4 OK), cfg `0x110`, cfg `0x6c`.
- dhd then fails in **`dhdpcie_scan_resource`** (BAR enumeration). The `dhdpcie_pci_probe+0x26c`
  cleanup path (`osl_mfree → pci_disable_device → osl_detach`) runs right after scan_resource
  returns failure; `pci_disable_device` warns "disabling already-disabled device" (benign).
- `dhdpcie_dongle_attach` and `si_attach` are **NEVER reached** (breakpoints at
  base+0x4dfd0 / +0x4e104 / +0x4e4bc did not fire). So the failure is **before** chipid/EROM/IPC.

**Device-model extensions made for CP-2** (`device-model/broadcom-fmac-stub.c`):
- added a `config_read` trace hook (logs every dhd config read → revealed the 0x00/0x110/0x6c gate),
- turned the model into a **PCI Express endpoint** (`INTERFACE_PCIE_DEVICE`,
  `QEMU_PCI_CAP_EXPRESS`, `pcie_endpoint_cap_init` @0x44) so the PCIe cap exists,
- stamped cfg `0x6c`=nonzero + `PCI_EXP_LNKSTA`=link-up (Gen2 x1) so `dhdpcie_prepare_pcie_ep`'s
  `tst w0,#0xf0` liveness check on 0x6c is satisfiable.

**Remaining blocker (the honest CP-2 frontier):** `dhdpcie_scan_resource` rejects the emulated
BAR layout before any backplane/chipid/IPC access. The device-model presents BAR0=0x4000 (reg
window) + BAR2=8 MiB 64-bit-prefetch (TCM); the real dongle's BAR sizing/decoding that
`dhdpcie_scan_resource` expects is not yet matched. Two open data points to resolve next:
- cfg `0x110` currently returns uninitialized QEMU ext-config (`0x62737973`); real dongle has a
  defined VSEC/ext-cap there — `dhdpcie_prepare_pcie_ep` reads it.
- `dhdpcie_scan_resource`'s exact BAR acceptance criteria (size/count/window) — disasm of
  `dhdpcie_scan_resource` in dhd.ko is the next RE step; then size BAR0/BAR2 to match.

This is **upstream of** the `pcie_ipc_t` / ring / doorbell / D2H / HME capture. Therefore the
real-IPC layout (SPEC §2/§3/§4/§6/§7/§9) could **not** yet be RE-CONFIRMED from a live dhd —
that capture is gated behind getting dhd past `dhdpcie_scan_resource`. The synthetic
`bcmfmac-probe` transcript (`handshake-distilled.txt`) remains the only end-to-end IPC trace;
its offsets stay `[DYN]`/`[SDK]`, NOT yet `[RE-CONFIRMED]` by real dhd.

---

## 4. M3 go/no-go (HME/MLO entanglement) — verdict: UNDETERMINED, leaning feasible-to-test

M3 (HME + doorbell-gen + D2H sync) is the make-or-break gate. We did **not** reach it: dhd
stops in BAR-resource scan, well before ring/HME setup. So we cannot yet answer empirically
whether a WI64-only (no-HME/no-MLO) port is possible.

What we CAN say from this run:
- The path to M3 is now **mechanically unblocked** at the kernel/loader level — the real dhd
  loads and probes; only device-model fidelity (BAR layout, ext-config) stands between here and
  the IPC stage. That is iterative device-model work, not a structural wall.
- No evidence yet that HME/MLO is entangled into the *early* probe (chipid/EROM/IPC-rev gate)
  — dhd fails before those. The entanglement question is answerable once dhd reaches
  `dhdpcie_dongle_attach → si_attach → read_pcie_ipc`.

Recommendation: continue CP-2 by RE'ing `dhdpcie_scan_resource` + sizing the model's BARs,
then `dhdpcie_prepare_pcie_ep`'s 0x110 VSEC, to drive dhd into si_attach and the shared-struct
read — at which point the SPEC `[DYN]` fields become RE-confirmable and M3 becomes assessable.
HALT per instructions before M3/M4.

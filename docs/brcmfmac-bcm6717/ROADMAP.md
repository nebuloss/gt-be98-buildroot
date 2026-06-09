# ROADMAP — Open FullMAC (brcmfmac) for BCM6717a0 / BCM6726b0 (GT-BE98)

Status: **RESEARCH-GRADE / EXPLORATORY.** This is the critical-path plan to a
working *open-source* FullMAC driver for the GT-BE98 WiFi radios. It is honest
about feasibility (low, multi-month, WiFi-7 features out of scope) and concrete
about the path. It consolidates four work-streams committed to this branch:

| Artifact | Commit | Path |
|---|---|---|
| Chip-support prototype (3 patches) | `b8334fe` | `docs/brcmfmac-bcm6717/patch/000{1,2,3}-*.patch` |
| PCIe-IPC protocol SPEC (565 lines) | `0f6e7c4` | `docs/brcmfmac-bcm6717/PCIE-IPC-SPEC.md` |
| QEMU dynamic-RE harness + captured trace | `973277e` | `qemu-harness/` |
| FullMAC-mode reachability verdict | this doc §1 | (RE memo, summarized below) |

Read order for a follow-on agent: this ROADMAP → `PCIE-IPC-SPEC.md` →
`qemu-harness/README.md` → the three patches.

---

## 0. Executive summary

- **Can this hardware run FullMAC at all?** YES, definitively. `dhd.ko` already
  drives 6717/6726 in FullMAC mode today; the dongle firmware `rtecdc.bin`
  exists for both parts; mode is a *host driver choice*, not an OTP/strap lock.
- **Can the OPEN `brcmfmac` drive them as-is?** NO. Three independent hard walls:
  no chip-table entry, an incompatible PCIe transport (Broadcom "BCA PCIe IPC"
  rev `0x8B`, not brcmfmac `pcie_shared` v5–7), and a v17 dongle ABI with
  WiFi-7 layers (HME, MLO-IPC) that have no counterpart in brcmfmac.
- **Verdict on the whole approach (GO / NO-GO):** **CONDITIONAL-GO, research-only.**
  The msgbuf *upper layer* (opcodes 0x1–0x12) is reusable; the *transport* must
  be rewritten. This is feasible as a research effort but is NOT a path to a
  shipping open WiFi driver, and delivers **no openness gain over keeping
  `dhd.ko`** (it swaps one closed blob — `rtecdc.bin` — for another). The
  standing program decision stands: **keep the wl/dhd blob; do openness work in
  the userspace control plane.** This branch exists to (a) keep the door open,
  (b) capture the protocol while the bench/tooling is warm, and (c) de-risk a
  future decision with a real, runnable harness rather than a paper estimate.

The single thing that converts this from "paper RE" to "runnable port" already
exists: the **QEMU harness boots a kernel, presents the device, and captures the
dhd handshake end-to-end.** Every remaining UNKNOWN is now a *dynamic-capture*
task against that harness, not a static-disasm guess.

---

## 1. FullMAC reachability — the go/no-go, settled

Two questions, answered separately. Evidence files at the bottom of this section.

### Q1: Can the silicon run FullMAC? → **YES.**
- `dhd.ko` is present, `intree: Y`, and its embedded chip-support strings name
  **6717, 6726, 6715, 43684** — the exact GT-BE98 radios.
- Dongle firmware `rtecdc.bin` exists for both parts (`6717a0/release/`,
  `6726b0/release/`) with valid **LFOC** container headers; dhd's firmware-path
  template (`…/release/rtecdc.bin`, `/mfgtest/rtecdc.bin`, `rtecdc.map`,
  per-chip `.nvm`) matches the on-device layout exactly.
- **Mode is not locked.** Both `wl.ko` and `dhd.ko` claim the identical PCI match
  `bc02sc80i` (class `0x028000`) — they compete for the same device. Load
  `wl.ko` → SoftMAC (host MAC/PHY); load `dhd.ko` + download `rtecdc.bin` →
  FullMAC (dongle MAC). `dhd`'s `op_mode` iovar selects AP/STA/APSTA.

### Q2: Can OPEN brcmfmac drive them? → **NO** (three independent fatal walls).
1. **Chip table (fatal alone):** brcmfmac's `BRCMF_FW_ENTRY` table
   (`pcie.c:64–80`) and `brcmf_chip_name()` (`chip.c`) top out at 4366/4371/43664
   (WiFi-5). No entry for 6717/6726/6715/43684 — it won't recognize the silicon.
   *(Patches 0001–0003 begin closing this wall; see §2.)*
2. **PCIe transport (the documented blocker):** brcmfmac accepts only
   `pcie_shared` versions **5–7** (`pcie.c:140–142`, reject at `pcie.c:1409`).
   The dongle does not expose a v5–7 struct at all; it speaks **BCA PCIe IPC**
   (rev `0x8B` = BCA-bit | ver `0x0B`) — a different, FWID/revision-negotiated
   transport with **HME** (Host Memory Extension) and **MLO IPC** layers that
   have no analogue in brcmfmac's `msgbuf.c`. Not a version bump; a rewrite.
3. **Firmware/ABI generation gap:** dongle banner is
   `Dongle Host Driver, version 17.10.369.39012 (r839077) BSPv1W13` (HND/dhd 17.x).
   brcmfmac's msgbuf/pcie targets the ~7.x–13.x generation; WiFi-7 (MLO, HME,
   320 MHz) is unrepresented.

**Net:** to use brcmfmac you must add the chip IDs, re-implement the entire BCA
PCIe IPC + HME (+ optionally MLO-IPC) transport from scratch, and match a v17
dongle ABI. The reusable part is the upper msgbuf layer (opcodes identical).
This is the "research-grade, WiFi-7-unsupported" effort flagged in the prior
`broadcom-driver-reimpl-verdict` memo — now upgraded from estimate to a
runnable harness + a decoded protocol spec.

Evidence: `dhd.ko`/`wl.ko` at
`…/base-rootfs/lib/modules/4.19.294/extra/{dhd,wl}.ko`; firmware at
`…/base-rootfs/rom/etc/wlan/dhd/{6717a0,6726b0}/release/rtecdc.bin`; nvram at
`…/rom/etc/wlan/nvram/GT-BE98.nvm` (boardtype 0xa5e, sromrev 19); brcmfmac limits
at `…/brcm80211/brcmfmac/pcie.c:{64-80,140-142,1409}` and `msgbuf.c`.

---

## 2. What exists today (assets in hand)

**(A) Chip-support prototype — patches 0001–0003 (`b8334fe`).** Makes the device
*recognizable* and wires firmware-name/chip-id plumbing into the in-repo SDK
brcmfmac (`…/src-rt-5.04behnd.4916/kernel/linux-4.19/…/brcm80211/`).
- `0001` — `brcm_hw_ids`: chip-id + PCIe device-id defines for 6717/6726.
- `0002` — `pcie.c` devid table + fw-name map entries (`rtecdc.bin`/nvram paths).
- `0003` — `brcmf_chip_get_raminfo` CA7 core case note.
- These do **not** make WiFi work — they get past wall #1 only. The transport
  (wall #2) is untouched; that is the body of this roadmap.

**(B) PCIe-IPC SPEC (`0f6e7c4`) — the protocol, decoded.** 13 sections; the load-
bearing ones for the port:
- §0 blocker; §1 identity/RAM sizing (CA7, `SYS_MEM`+`SMAR`).
- §2 `pcie_ipc_t` 128 B shared struct — full offset table + `flags` bitfield.
- §3 two-gate handshake (hard IPC-rev gate `hcap1[7:0]`; soft FWID/logstrs gate).
- §4 `pcie_ipc_rings_t` 128 B + 16 B `pcie_ipc_ring_mem_t` (new `item_type` byte;
  `D2H_COMMON=6` delta vs brcmfmac).
- §5 work-item formats (legacy WI64 vs ACWI/CWI) + "negotiate WI64" minimal-port
  strategy.
- §6 **HME** (mandatory) + HYBRIDFW HMOSWP sub-case.
- §7 doorbell/mailbox (H2DMB/D2HMB bits + newer `_2` doorbell-register gen).
- §8 LFOC container (header decoded, payload = `rtecdc[0x0C:]`,
  resetvec = `le32(rtecdc[0x0C])`, embedded CLM, nvram format).
- §9 D2H SEQNUM sync + livelock guard; §10 per-TID flowrings; §11 MLO IPC
  (deferrable); §12 end-to-end load sequence; §13 ordered work items +
  firmware.c/pcie.c edit sketch + remaining `[DYN]` list.
- Confidence tags preserved: `[RE-CONFIRMED]` / `[SDK]` / `[DYN]`.

**(C) QEMU dynamic-RE harness (`973277e`) — the bench.** Boots 4.19.294 aarch64
under `qemu-system-aarch64 -M virt`, presents an emulated Broadcom FullMAC PCIe
device (vendor `0x14e4`, class `0x028000`) matching dhd's alias, and **runs the
entire early IPC handshake end-to-end**, logged from both device-model and probe
driver. Captured path (`qemu-harness/traces/handshake-distilled.txt`):
1. boot + PCIe enumerate; realize `vendor=0x14e4 device=0x6717`.
2. class-match probe (`PROBE vendor=0x14e4 class=0x028000`).
3. BAR0 (reg window) + BAR2 (8 MiB TCM) mapped.
4. **`si_attach` chipid read PASSES** (`BAR0_WINDOW=0x18000000` → chipid
   `0x00006717`) — dhd's first hard gate.
5. firmware download into TCM (LFOC-shaped, byte-counted).
6. core release → device publishes candidate IPC shared struct
   (`shared-ptr @TCM[0x3ffffc]=0x1000`, `rev=0x06`).
7. **`read_pcie_ipc` captured** — driver follows the pointer, reads `word0=0x06`,
   device logs `>>> IPC training commences <<<`; full 0x00–0x3c window dumped.
8. **doorbell + MSI round-trip** (`H2D_MAILBOX_0=1` → MSI → ISR
   `MAILBOXINT=0xf000` → W1C ack).
- Device-model `broadcom-fmac-stub.c` (504 lines) compiles into QEMU 10.0.0,
  exposes tunable qdev props (`chipid`, `ipc-rev`, `ram-base/size`,
  `shared-ptr-off`, `shared-info-off`) so the shared struct can be iterated
  toward a real dongle layout with **no recompile**. Register offsets are
  verbatim from brcmfmac `pcie.c`; the state machine is driven by dhd's own
  extracted IPC error strings.
- Built artifacts: QEMU at `/home/guillaume/qemu-src/qemu-10.0.0/build/qemu-system-aarch64`;
  stock harness kernel `Image` at `/home/guillaume/qemu-src/linux-4.19.294/arch/arm64/boot/Image`.

---

## 3. Critical-path next steps (ordered)

The harness proved the upper handshake works against a *synthetic* shared struct.
The port now needs the *real* dongle's field values + ABI behaviour. Critical
path, in order — each step gates the next:

**CP-1 — Build the disposable "harness kernel" (unblocks all dynamic capture).**
The real `dhd.ko` cannot load on a stock kernel (276 merlin-only vmlinux symbols
missing: `bcm_printk`, `blog_clone_wlan`, `nbuff_free_ex`, `wlcsm_nvram_*`,
`gbpm_g`, `BcmHalMapInterrupt`, `__mlo_ipc_mlc_state_str`, …; see
`traces/dhd-missing-symbols.txt`, `traces/dhd-load-attempt.log`). The merlin
kernel that exports them **panics under `-M virt`** in
`bcm_ubus_drv_init → bcm_ubus_config` (a SoC-fabric `postcore_initcall` touching
absent hardware) and lacks `PCI_HOST_GENERIC` (`traces/merlin-kernel-virt-panic.log`).
- *Fix:* build a one-off kernel from merlin 4.19.294 source — add
  `PCI_HOST_GENERIC` + `VIRTIO`, **stub the faulting SoC `postcore_initcall`s**
  (bcm_ubus / strap / PMC) while **keeping** the `nbuff`/`blog`/`knvram`
  `EXPORT_SYMBOL`s the dhd dep-chain needs (independent of UBUS init).
- The `initramfs-dhd.cpio.gz` + `init.c` to `finit` the full 12-module dep chain
  against the same device-model are **already built and staged**.
- *Exit:* merlin-kernel + dhd dep chain boot under `-M virt`; `insmod dhd.ko`
  reaches probe without a missing-symbol or fabric panic.

**CP-2 — Capture the REAL shared-struct + ring layout (the prize).**
With CP-1 booted, enable dhd's verbose `dyndbg` and let the *real* dhd drive the
device-model's tunable fields. dhd's reads/writes reveal the true
`pcie_ipc_t` offsets, the `rev` byte, `hcap`/`hcap1` capability words, ring-mem
offsets, and `item_type`. Iterate the qdev props until dhd stops rejecting the
struct and proceeds to ring setup.
- *Exit:* a byte-accurate `pcie_ipc_t` + `pcie_ipc_rings_t` map confirmed by a
  live dhd that accepts it (replaces every `[DYN]`/`[SDK]`-only field in the SPEC
  with `[RE-CONFIRMED]`). This is the data the open back-end is written against.

**CP-3 — Capture HME bind + doorbell-gen + D2H sync behaviour.**
Continue the live run past struct accept: record the **HME** bind sequence
(`HME bind PCIE IPC`, `SBTOPCIE` window programming — SPEC §6), which doorbell
register generation the v17 fw uses (`_2` vs legacy — §7b), and the D2H SEQNUM /
livelock-guard behaviour (§9). These are the three areas with no brcmfmac
equivalent and the highest implementation risk.
- *Exit:* HME + doorbell + D2H sync sequences logged and documented; SPEC §6/§7/§9
  promoted to `[RE-CONFIRMED]`.

**CP-4 — Implement the open BCA-PCIe-IPC transport back-end.**
Write the new transport behind brcmfmac's existing msgbuf upper layer (opcodes
0x1–0x12 reused unchanged). Scope per SPEC §13 + §5 "negotiate WI64" minimal-port
strategy:
- shared-struct reader/validator for rev `0x8B` (replace the v5–7 gate);
- LFOC strip + RAM download (payload `rtecdc[0x0C:]`, resetvec `le32(@0x0C)`, §8);
- ring init with the 16 B `pcie_ipc_ring_mem_t` + `item_type`, `D2H_COMMON=6`;
- HME allocate/bind (§6);
- doorbell/mailbox + MSI ISR (already validated end-to-end in the harness, §7);
- D2H completion consume with SEQNUM sync (§9);
- WI64 work-items only (defer ACWI/CWI, MLO-IPC §11, per-TID flowrings §10).
- *Exit:* against the harness, the open back-end completes the same transcript
  the synthetic probe did — but driven by *real* fw and the open code path.

**CP-5 — Bench bring-up on real silicon (STA-only first).**
Load the open module on a real GT-BE98 (recovery channel + open-flash baseline
already exist for safe rollback). Target the simplest mode first: `op_mode` STA,
no Runner offload ("Force disabling Runner Offload TX/RX" — offload is OPTIONAL),
single link, no MLO. Iterate against real fw behaviour the harness can't model.
- *Exit:* associate + pass traffic as a STA on one band via the open driver.

Deferred / explicitly out of scope for the research milestone: AP mode beyond
basic, MLO/WiFi-7, 320 MHz, ACWI/CWI work-items, Runner/flowring HW offload.

---

## 4. Remaining UNKNOWNS — and how QEMU now captures each

The harness converts every former static guess into a dynamic-capture task. Each
UNKNOWN below now has a concrete capture method (all gated on CP-1):

| UNKNOWN | SPEC ref | How QEMU captures it (post-CP-1) |
|---|---|---|
| Real `pcie_ipc_t` offsets + `rev`/`hcap`/`hcap1` words | §2, §3 | Live dhd reads the device-model's tunable shared window; tune props until accepted; log the offsets dhd actually touches. |
| Ring mem layout: 16 B `pcie_ipc_ring_mem_t`, `item_type`, `D2H_COMMON=6` | §4 | dhd programs ring addresses into TCM during init — device-model logs every TCM write at ring-setup. |
| WI64 vs ACWI/CWI negotiation | §5 | Observe which work-item size dhd negotiates after struct accept. |
| HME bind sequence + `SBTOPCIE` windows | §6 | Log dhd's HME allocate/bind register programming live. |
| Doorbell register generation (`_2` vs legacy) | §7b | Already see MSI round-trip on the synthetic path; confirm which doorbell offsets *real* dhd kicks. |
| LFOC: must payload be stripped at 0x0C before download? resetvec handling | §8a | Watch the byte range + reset-vector write dhd issues during real fw download. |
| CA7 TCM/RAM base + reset-vector for 6717/6726 silicon revs | §1 RAM sizing | dhd's `SYS_MEM`/`SMAR` reads are logged by the device-model. |
| D2H SEQNUM sync + livelock guard timing | §9 | Replay D2H completions from the device-model and watch dhd's consume loop. |
| Exact PCIe device-id presented on config space (dhd ignores it; class-matches) | README KNOWN/UNKNOWN | qdev prop already settable; confirm against real config-space dump. |
| nvram devpath/`N:` prefix tolerance in any open parser | §8e | N/A in QEMU (host-side parse); validate at CP-4 in code. |

The two structural UNKNOWNS that QEMU *cannot* fully model (need real silicon,
CP-5): true PHY/RF bring-up timing, and any fw behaviour keyed on real backplane
state rather than the synthetic device-model.

---

## 5. Milestone breakdown + realistic effort

Effort assumes one engineer fluent in kernel PCIe + Broadcom msgbuf, working
from the SPEC + harness. Ranges are honest, not optimistic; the dominant risk is
HME/MLO and v17-ABI surprises that only surface on real silicon.

| Milestone | Maps to | Effort | Risk | Gate to proceed |
|---|---|---|---|---|
| M0 — chip recognized (patches 0001–0003 build clean in SDK tree) | §2 (A) | DONE-ish (~3–5 d to compile-verify) | low | brcmfmac probes, fails at transport gate (expected) |
| M1 — harness kernel boots, real dhd loads | CP-1 | 1–2 wk | med (SoC initcall stubbing) | `insmod dhd.ko` reaches probe under `-M virt` |
| M2 — real shared-struct + ring layout captured | CP-2 | 1–2 wk | low (mechanical once M1 done) | byte-accurate `pcie_ipc_t`/`rings_t`, every `[DYN]`→`[RE-CONFIRMED]` |
| M3 — HME + doorbell-gen + D2H sync captured | CP-3 | 2–3 wk | **high** (no brcmfmac analogue) | §6/§7/§9 documented from live trace |
| M4 — open BCA-PCIe-IPC transport back-end (WI64, STA, no offload) | CP-4 | 6–10 wk | high | open back-end reproduces harness transcript |
| M5 — real-silicon STA bring-up (associate + traffic) | CP-5 | 4–8 wk | **very high** (PHY/RF, real-fw quirks) | STA assoc + data path on one band |
| (deferred) AP mode, MLO/WiFi-7, offload, ACWI/CWI | §10/§11 | unbounded | n/a | out of research scope |

**Total to research-grade STA on one band: ~4–7 months**, consistent with the
prior reimpl memo. M4+M5 dominate; M3 is the make-or-break technical risk. There
is **no** path here to AP/MLO/WiFi-7 within a reasonable horizon — the shipping
router config (tri-band AP, MLO) stays on `dhd.ko`.

---

## 6. What a follow-on workflow should do next

Strictly ordered; the first item unblocks everything and is the only thing worth
doing before re-evaluating the whole effort:

1. **Execute CP-1 (M1): build the disposable harness kernel.** From merlin
   4.19.294 source: add `PCI_HOST_GENERIC`+`VIRTIO`, stub `bcm_ubus`/strap/PMC
   `postcore_initcall`s, keep the `nbuff`/`blog`/`knvram` `EXPORT_SYMBOL`s. The
   `initramfs-dhd.cpio.gz` + `init.c` are already staged. Boot it under the
   existing harness; `insmod` the 12-module dep chain + `dhd.ko`. Commit the
   kernel `.config` diff + the stubbing patch to `qemu-harness/harness-kernel/`.
2. **Execute CP-2 (M2): capture the real shared-struct + rings** with verbose
   dhd `dyndbg` driving the tunable device-model. Update `PCIE-IPC-SPEC.md`
   §2/§3/§4 in place, flipping `[DYN]`/`[SDK]` → `[RE-CONFIRMED]`, and drop the
   raw trace into `qemu-harness/traces/`.
3. **Execute CP-3 (M3): capture HME + doorbell-gen + D2H sync.** This is the
   go/no-go technical gate for M4. If HME/MLO entanglement makes a WI64-only
   minimal port impossible, **stop and record NO-GO** — do not start M4.
4. **Only if M1–M3 clean:** scope M4 (CP-4) as its own multi-week effort behind
   an explicit operator GO, since it delivers no openness gain over `dhd.ko` and
   competes with higher-value userspace control-plane work.

Standing guardrails for any follow-on:
- This is a **side research branch.** Do not let it block or alter the committed
  open-OS baseline (OpenRC PID1, slot 2). No real-silicon flashing before M5, and
  M5 only behind the existing recovery channel + open-flash rollback.
- Keep `dhd.ko`/`wl.ko` in the shipping image. brcmfmac is **not** a shipping
  driver here and this roadmap does not change that.
- Update the `broadcom-driver-reimpl-verdict` memory memo if any milestone gate
  flips the feasibility verdict.

---

## 7. Bottom line

FullMAC is reachable; the *open* path is feasible only as months-long,
WiFi-7-less, STA-first research, and yields **no openness gain** over the blob it
would replace. What this campaign delivered is real and durable: a decoded
transport SPEC, a runnable QEMU harness that captures the dhd handshake live, and
chip-support patches — i.e. the UNKNOWNS are now dynamic-capture tasks, not
guesses, and the next agent can execute CP-1→CP-3 to settle the M3 go/no-go
before anyone commits to the M4 rewrite.

---

## 8. M3 verdict — from REAL-HARDWARE dhd capture (2026-06-09)

**Method.** On the live GT-BE98 (4x BCM6726b0, committed v34): `rmmod wl` (SSH
survived over the wired br0 lifeline — confirmed safe, 3/3), then `insmod dhd.ko`
with high `dhd_msg_level`, draining dmesg to /jffs flash at 50 ms (the only way
to capture up to a hard hang). Real dhd executed **everything the QEMU harness is
still synthesizing** (real EROM + PCIe2/CA7/SYS_MEM cores, `dhdpcie_dongle_attach`)
and got as far as the firmware download before **hard-hanging the SoC**. Trace:
`qemu-harness/traces/realhw/{03-dhd-probe-realhw-kmsg.log,04-dhd-realhw-DISTILLED.md}`.

**What real HW settled (CP-2-equivalent, partial CP-3):** §1 chip/devid/RAM/
backplane, §5 WI64 control-ring sizes (40/24, item_type 0), §6 HME *allocation*
presence (26 MB BHM) — all promoted to `[RE-CONFIRMED]` in the SPEC. The deep IPC
handshake (shared-struct read §2/§3, ring D2H sync §9, doorbell gen §7b, HME
*bind* §6, MLO bring-up §11) was **NOT** captured: it is downstream of the fw
membytes-DMA download, which **wedges the PCIe/AXI fabric and hangs the kernel**
on this box (reproducible 3/3; watchdog auto-resets to v34). Cause: the merlin
`bcm_pcie_hcd` RC + runner/rdpa stack stays resident and already owns these 4
links; dhd re-driving the same EP (backplane reset + download DMA) collides at the
hardware-fabric level. This is a *bench-setup* limit, not a protocol verdict — but
it does mean the dongle-side IPC bytes can't be read on a stock-but-wl-removed
image.

**The M3 question — is a WI64-only open back-end (no HME/MLO) portable, or are
HME/MLO entangled into core bring-up? → ENTANGLED. Verdict: NO-GO for a
HME/MLO-free minimal port.** Empirical evidence from the real init path, in order,
**all before** firmware download / any link:

1. `dhd_prot_host_mem_alloc: Alloc Legacy Host Memory DMA Buffer len 1314816` and
   `dhdpcie_bhm_mem_alloc: PCIe IPC BHM ALLOC SUCCESS: size 26MB` — **HME/BHM is
   allocated unconditionally during attach**, not as an optional post-link
   feature. It sits *inside* the mandatory bring-up, consistent with SPEC §6
   ("MANDATORY before link"). A WI64-only port still has to implement the HME
   allocate+bind handshake to get the dongle to link at all.
2. `dhd_mlo_ipc_init: ENTER ap_unit[0] mlo_unit[-1]` — **MLO-IPC init runs on the
   core path even for a single, un-bound unit** (mlo_unit = -1). It is woven into
   `dhd_attach`, not gated behind an MLO config. A port can likely leave the MLD
   *un-bound* (mlo_unit stays -1, the MLC_* mailbox states never fire), so MLO
   *bring-up* is probably skippable — but the MLO-IPC *init/HME-user* scaffolding
   is on the unconditional path and must at least be tolerated.

So §3's "negotiate WI64, advertise no ACWI, defer HME/MLO" minimal strategy is
**only half-valid**: WI64 control rings are confirmed real and reusable (good),
but **HME is not deferrable** — it is a hard prerequisite of the link, with no
brcmfmac analogue, and is the single biggest net-new implementation chunk (as M3's
"make-or-break, high-risk" rating predicted). MLO bring-up stays deferrable; MLO
init scaffolding does not.

**Consequence for the milestones.** M3's go/no-go specifically asked whether
HME/MLO entanglement makes a WI64-only minimal port impossible. **HME entanglement
is now empirically confirmed** — M4 cannot skip HME. That does not kill the
research path, but it *removes the cheapest version of M4* (the "WI64 + no HME"
shortcut) and re-confirms HME (§6) as a mandatory, from-scratch M4 deliverable.
Combined with the standing finding that the open port yields **no openness gain**
over `dhd.ko` (it still needs the closed `rtecdc.bin`), the recommendation stands:
**do NOT start M4.** Keep `dhd.ko`/`wl.ko` shipping; this branch remains research.

**Two residual captures still need a cleaner bench** (a kernel/image where the
merlin RC+runner stack is *not* resident, so the fw-download DMA doesn't collide —
i.e. the disposable harness kernel of CP-1, but booted on real silicon, or a
build that loads dhd *instead of* the runner stack from boot): the shared-struct
read (§2/§3 byte layout) and the HME *bind* + doorbell-gen + D2H-sync (§7/§9).
Until then those stay `[DYN]`/`[SDK]`. The QEMU CP-2b path (extend synthetic EROM
to multi-core) and this real-HW path now bracket the same gap from both sides.

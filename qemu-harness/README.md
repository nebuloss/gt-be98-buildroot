# QEMU FullMAC dynamic-RE harness (Approach A)

A QEMU `aarch64 -M virt` harness that boots a 4.19.294 kernel, presents a minimal
emulated **Broadcom PCIe FullMAC device-model** matching ASUS's closed `dhd.ko`
alias (`pci:v000014E4d*sv*sd*bc02sc80i*` — vendor `0x14e4`, class `0x028000`), and
captures the **PCIe-IPC handshake / shared-struct / ring-setup trace** that the
open `brcmfmac` driver cannot speak.

This implements **Approach A** from the QEMU-strategy analysis: run the closed
driver against a synthetic device far enough to observe the post-v7
*BCA-PCIe-IPC* negotiation (the one unknown blocking any brcmfmac port).

## What it contains

| Path | What |
|---|---|
| `device-model/broadcom-fmac-stub.c` | QEMU `PCIDevice` model. Config space (14e4 / class 0x028000 / MSI / 64-bit prefetch BAR), **BAR0** backplane register window with a sliding `BAR0_WINDOW` (cfg 0x80) that serves the ChipCommon **chipid** (`0x6717`) so `si_attach` proceeds, **BAR2** = 8 MiB TCM (dongle RAM, the trace surface), mailbox/doorbell regs at the exact brcmfmac offsets (`0x48/0x4C/0x90/0x94/0x98/0x140/0x144`), and an iterative **BCA-PCIe-IPC handshake state machine** (fw-download → core-release → publish candidate shared struct → training → doorbell+MSI). Every BAR/TCM access is logged. Tunable via qdev props (`chipid`, `chiprev`, `ipc-rev`, `ram-base/size`, `shared-ptr-off`, `shared-info-off`) so the iteration loop needs no recompile. |
| `device-model/bcmfmac-probe.c` | A minimal in-tree PCI driver that **replays dhd's early probe order** (si_attach chipid read → fw download → core-release → `read_pcie_ipc` → doorbell+MSI) so the device-model is exercised + traced on a stock kernel that lacks ASUS's 12 Broadcom dep modules. |
| `rootfs/init.c` | Static aarch64 PID1: mounts pseudo-fs, enables `dynamic_debug` for `dhd`/`brcmfmac`, lists the PCI bus, `finit_module`s whatever `.ko`s are present, powers off. Scriptable, non-interactive. |
| `scripts/config.env` | Absolute paths (toolchain, QEMU, kernels, dhd.ko, firmware). |
| `scripts/apply-to-qemu.sh` | Injects the device-model into a QEMU source tree (Kconfig + meson) and builds `qemu-system-aarch64`. Idempotent. |
| `scripts/build-probe-and-initramfs.sh` | Builds `bcmfmac_probe.ko` + static init + the probe initramfs. |
| `scripts/run-harness.sh` | Boots the stock kernel + device-model + probe initramfs and captures the handshake trace to `traces/handshake.log`. |
| `traces/handshake.log` | Full boot+handshake console. |
| `traces/handshake-distilled.txt` | The headline transcript (device-model + driver lines, in order). |
| `traces/dhd-load-attempt.log` | Attempt to load the **real** `dhd.ko` + deps on the stock kernel. |
| `traces/dhd-missing-symbols.txt` | The 276 vmlinux symbols the closed deps require (the next blocker). |
| `traces/merlin-kernel-virt-panic.log` | The merlin BCM6813 kernel panicking under `-M virt` (the other half of the blocker). |

## How far it got — WORKING end to end

`scripts/run-harness.sh` produces, in order (from `traces/handshake-distilled.txt`):

1. **Stock 4.19.294 kernel boots on `-M virt`**, enumerates the generic PCIe host
   bridge, and the device-model realizes: `vendor=0x14e4 device=0x6717 class=0x0280`.
2. **The 14e4 device is probed by class match** —
   `matched device 0000:00:02.0 ... PROBE vendor=0x14e4 device=0x6717 class=0x028000`.
3. BAR0 (16 KiB) + TCM (8 MiB) mapped.
4. **`si_attach` chipid read succeeds**: the driver sets `BAR0_WINDOW=0x18000000`
   and reads ChipCommon → device returns `0x00006717` (id=0x6717 rev=0). This is the
   first hard gate in dhd's probe and it passes.
5. **Firmware download** into TCM observed (64 KiB; first write @0x0, device counts bytes).
6. **Core release** → device publishes a candidate PCIe-IPC shared struct:
   `shared-ptr @TCM[0x003ffffc] = 0x00001000`, `shared-info rev=0x06`.
7. **`read_pcie_ipc` observed (THE PRIZE):** the driver reads the shared pointer,
   follows it, reads `word0 = 0x00000006`, and the device logs
   `>>> IPC training commences <<<`. The full 0x00–0x3c window of the shared
   struct is dumped by both sides (`*** TCM read SHARED-INFO ...`).
8. **Doorbell + MSI round-trip:** driver writes `H2D_MAILBOX_0=1` → device raises MSI
   → ISR fires with `MAILBOXINT=0x0000f000` → W1C ack. Bidirectional path proven.

So the strategy's minimum-bar deliverable ("QEMU boots the kernel + a fake 14e4
device that dhd probes + the first shared-struct read is observed") is **met and
exceeded**: the full early handshake (chipid → fw-download → shared-struct read →
training → doorbell/MSI) runs and is captured, with a tunable device that can be
iterated to match whatever a real dongle exposes.

## The next blocker (two coupled walls)

The **real** `dhd.ko` could not be loaded *in this run* — not because of the
device-model, but because of the kernel ABI:

1. **dhd's 12 closed deps need 276 distinct vmlinux symbols that only exist in the
   merlin BCM6813 kernel** (`traces/dhd-missing-symbols.txt`): `bcm_printk`,
   `blog_clone_wlan`, `_blog_finit`, `nbuff_free_ex`, `wlcsm_nvram_*`, `gbpm_g`,
   `BcmHalMapInterrupt`, `arch_setup_dma_ops`, `netdev_path_get_root`,
   `__mlo_ipc_mlc_state_str`, … — i.e. the SoC nbuff/blog/runner/knvram fabric.
   A stock vanilla kernel does not export these, so `bcmlibs/hnd/bdmf/wlshared/...`
   fail `finit_module` with `Unknown symbol` (the harness loads them anyway to
   record the exact list).
2. **The merlin kernel (which *does* export them) panics under `-M virt`**
   (`traces/merlin-kernel-virt-panic.log`): a `postcore_initcall`,
   `bcm_ubus_drv_init → bcm_ubus_config`, writes to a SoC UBUS-fabric register that
   does not exist on `-M virt` → `Unable to handle kernel write to read-only memory`
   → fatal. It also lacks `PCI_HOST_GENERIC`, so even past that it would see no PCI bus.

**To run the real dhd.ko, the next step is a "harness kernel": the merlin 4.19.294
source reconfigured for `-M virt`** — add `PCI_HOST_GENERIC` + `VIRTIO`, and stub or
disable the SoC `postcore_initcall`s that fault (`bcm_ubus`, strap, PMC, memory
controller) WITHOUT dropping the EXPORT_SYMBOLs the dhd deps need (those are mostly
in nbuff/blog/knvram, which are independent of the UBUS init). That kernel keeps the
exported-symbol set dhd's deps resolve against while surviving `-M virt` boot. It
must be built from a **disposable copy** of the kernel tree (the in-place SDK tree is
the shared, committed kernel-cve baseline and must not be perturbed). Once it boots,
swap `initramfs-dhd.cpio.gz` in (already built) and `init.c` will `finit_module` the
full chain against the same device-model — at which point dhd's own verbose dyndbg
(`PCIe IPC Revision compatibility: host 0x%02x, dngl 0x%02x`, `PCIE IPC address
invalid`, `LOCATION FAILURE daddr32 ...`) drives the device-model's shared-struct
fields to their real values, capturing the actual BCA-PCIe-IPC layout.

A lighter alternative the device-model already supports: keep iterating the
`bcmfmac-probe` exerciser against tunable props to reproduce specific dhd offsets
once they're known from static RE, without needing the merlin kernel to boot.

## Reproduce

```sh
cd qemu-harness
# 1. build QEMU with the device-model (once; ~10 min)
scripts/apply-to-qemu.sh /home/guillaume/qemu-src/qemu-10.0.0
# 2. build the probe module + initramfs
scripts/build-probe-and-initramfs.sh
# 3. run + capture trace
scripts/run-harness.sh                 # default 6717 / ipc-rev 6
scripts/run-harness.sh "chipid=0x6726,ipc-rev=8,ram-size=0x540000"   # 6726 variant
```

Prereqs: `qemu-system-arm` build deps (`ninja-build meson libglib2.0-dev
libpixman-1-dev`), the gcc-10.3 aarch64 cross toolchain, the QEMU 10.0.0 source, and
a stock `linux-4.19.294` (paths in `scripts/config.env`). The device-model source is
self-contained and version-pinned to the QEMU 10.0 device API.

## Register/offset provenance

All register offsets are taken verbatim from the merlin brcmfmac source
`drivers/net/wireless/broadcom/brcm80211/brcmfmac/pcie.c` (dhd uses the same
PCIe-gen2 block). The handshake state-machine steps and the verbose error strings
that drive iteration were extracted from `dhd.ko` itself (`.modinfo` alias/deps;
`PCIe IPC` / `BCA PCIe IPC REVISION` / `LOCATION FAILURE` / `Ring Hostready` strings;
`select_chipidverstr` naming 6717/6726/6715/43684). The firmware container is the
on-disk `rtecdc.bin` (`LFOC` magic + ARM CA7 vector table, 4.09 MB 6717 / 5.37 MB 6726).

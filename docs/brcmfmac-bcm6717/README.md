# brcmfmac BCM6717/BCM6726 chip-support — prototype additions

This directory holds the concrete brcmfmac additions to RECOGNIZE and begin
ATTACHING the GT-BE98's `dhd` FullMAC radios (BCM6717a0 / BCM6726b0) using the
on-device `rtecdc.bin` firmware.

These patches are RESEARCH-GRADE. They make the device *recognizable* and wire
the firmware-name/chip-id plumbing per the RE. They do **NOT** make wifi work on
their own — the firmware speaks Broadcom "PCIe IPC", not the "pcie_shared v5..7"
protocol that brcmfmac's msgbuf.c/pcie.c implement (see ANALYSIS.md §2). The
IPC-protocol port is the real work and is NOT in these patches.

Target tree (the in-repo SDK copy of brcmfmac, kernel 4.19):
  vendor/asuswrt-merlin.ng/release/src-rt-5.04behnd.4916/kernel/linux-4.19/
    drivers/net/wireless/broadcom/brcm80211/

Files:
  - 0001-brcm_hw_ids-add-6717-6726.patch   chip-id + pcie device-id defines
  - 0002-pcie-devid-and-fwnames.patch       devid table + fw-name map entries
  - 0003-chip-core-setup.patch              brcmf_chip_get_raminfo CA7 case note
  - ANALYSIS.md                             full RE: identity/protocol/fw/runner/verdict

## KNOWN vs UNKNOWN (one-line)

KNOWN (from RE, high confidence):
  - vendor 0x14e4; dhd matches by PCI *class* 0x028000 mask 0x00ffff00, ANY devid
  - chips: 6717a0, 6726b0 (also 6715/43684 referenced); ARM **CA7** core
  - firmware = rtecdc.bin, raw-ish ARM image inside an "LFOC" container header
  - fw version 17.10.369.39012; handshake = "PCIe IPC FWID 0x.. Rev host/dngl"
  - CLM is **embedded in rtecdc.bin** (no separate .clm_blob on device)
  - nvram = per-board GT-BE98.nvm, NUL-separated key=val text w/ devpath prefixes
  - runner/flowring offload is **OPTIONAL** ("Force disabling Runner Offload TX/RX")

UNKNOWN (needs bench / fw-internals):
  - the exact PCIe device-id the chip presents on its config space (dhd ignores it)
  - the "PCIe IPC" shared-struct layout + version int vs brcmf pcie_shared v7
  - whether the LFOC container must be stripped (offset 0x0C) before RAM download
  - CA7 TCM/RAM base + reset-vector handling for 6717/6726 silicon revs
  - whether brcmfmac's text-nvram parser tolerates the devpath/N: prefixes

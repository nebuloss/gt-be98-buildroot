# PCIe-IPC Protocol Specification — brcmfmac FullMAC back-end for BCM6717a0 / BCM6726b0

Consolidated implementation spec for porting the in-kernel `brcmfmac` driver to
attach the GT-BE98's `dhd` FullMAC radios. This document merges two reverse-
engineering passes — the PCIe-IPC protocol RE (struct/ring/sync/handshake) and
the firmware-container RE (LFOC/CA7/nvram/load-sequence) — into one coherent
reference, plus the exact code-level delta from stock brcmfmac so a developer can
implement the back-end without re-reading the binaries.

This SPEC supersedes the "UNKNOWN" bullet list in `README.md`: most of those
items are now resolved (the IPC struct layout, LFOC stripping, the version gate).
The remaining `[DYN]` items are flagged inline.

## Provenance & confidence tags

- **Ground-truth binaries:** on-device `dhd.ko` (aarch64, **not stripped**),
  `.../lib/modules/4.19.294/extra/dhd.ko`, build version
  **17.10.369.39012 (r839077) BSPv1W13**; firmware
  `.../dhd/{6717a0,6726b0}/release/rtecdc.bin`; nvram
  `.../rom/etc/wlan/nvram/GT-BE98.nvm`.
- **Authoritative SDK headers** dhd.ko was compiled against:
  `.../src-rt-5.04behnd.4916/bcmdrivers/broadcom/net/wl/impl103/main/components/proto/include/{bcmpcie.h,bcmmsgbuf.h}`
  (`bcmmsgbuf.h $Id: 836782 2024-02-21$`).
- **brcmfmac target tree** (in-repo SDK copy, kernel 4.19):
  `.../src-rt-5.04behnd.4916/kernel/linux-4.19/drivers/net/wireless/broadcom/brcm80211/brcmfmac/{pcie.c,chip.c,firmware.c,msgbuf.c}`.

Tags used throughout:
- **[RE-CONFIRMED]** — matches a literal string, symbol, or byte in the shipped binary/firmware.
- **[SDK]** — read from the exact SDK headers dhd.ko compiles against (authoritative struct/define; in-binary offset not independently re-derived).
- **[DYN]** — needs runtime / bench / further-disasm confirmation before coding can finalize.

## CP-2 dynamic-capture status (2026-06-09)

The QEMU harness now boots the disposable kernel, loads the **full closed dhd dep
chain**, and runs the **real `dhd.ko` probe** against the emulated 14e4 device
(the CP-1 `rdpa_gpl` loader fault is root-caused + fixed — see
`qemu-harness/traces/cp2-rdpa_gpl-rootcause-and-dhd-probe.md`). However, the live
dhd currently stops in **`dhdpcie_scan_resource`** (PCI BAR enumeration), which is
**upstream of** `si_attach`/chipid/EROM and the entire PCIe-IPC stage. Therefore:

- **No `[DYN]` item in §2–§9 has yet been promoted to `[RE-CONFIRMED]` from a live
  dhd run** — dhd does not reach the shared-struct/ring/doorbell/HME code on the
  current device-model. Promoting them would be unsupported; they remain `[DYN]`/`[SDK]`.
- The only end-to-end IPC transcript so far is the **synthetic** `bcmfmac-probe`
  exerciser (`qemu-harness/traces/handshake-distilled.txt`), which replays dhd's
  expected order against tunable props — it confirms the harness mechanism, not the
  real dongle's field values.
- Next dynamic-capture step (to start flipping `[DYN]`→`[RE-CONFIRMED]`): RE
  `dhdpcie_scan_resource`'s BAR acceptance + the cfg-0x110 VSEC that
  `dhdpcie_prepare_pcie_ep` reads, size the device-model BARs to match, and drive
  dhd into `si_attach → read_pcie_ipc`. Until then §2/§3/§4/§6/§7/§9 stay as tagged.

dhd.ko v17.10.369.39012 and both `rtecdc.bin` images are the **same firmware
train** (host/dongle FWID handshake matches), so the headers above describe
exactly what the firmware speaks.

---

## 0. Executive summary — the blocker, precisely

The firmware does **not** speak brcmfmac's `pcie_shared` v5–7 protocol. It speaks
Broadcom's newer **"PCIE_IPC"** framework. The on-dongle handshake area is a
*typed C struct* `pcie_ipc_t` (bcmpcie.h:897), **128 bytes**, advertising
revision **`PCIE_IPC_REVISION = 0x8B`** = `PCIE_IPC_BCA_REV (0x80)` | `PCIE_IPC_VERSION (0x0B = 11)`
(bcmpcie.h:135-142). **[SDK]**

Why stock brcmfmac dies instantly: `brcmf_pcie_init_share_ram_info()` (pcie.c:1407)
reads `shared->version = flags & BRCMF_PCIE_SHARED_VERSION_MASK (0x00FF)` and
rejects anything outside `[BRCMF_PCIE_MIN_SHARED_VERSION 5, MAX 7]`. The dongle's
`pcie_ipc::flags[7:0] = 0x8B (139)` → `Unsupported PCIE version` → `-EINVAL`. **[RE-CONFIRMED + SDK]**

**The good news:** the msgbuf upper-layer message-type opcodes are *identical*
(dhd `MSG_TYPE_*` 0x1–0x12 in bcmmsgbuf.h:160-181 == brcmfmac `MSGBUF_TYPE_*`
0x1–0x12 in msgbuf.c:40-57). The upper protocol, status codes, and control/
flowring messages are reusable. The break is entirely in:

| # | Net-new vs brcmfmac | Section |
|---|---------------------|---------|
| a | Shared-struct layout — typed `pcie_ipc_t`, not offset reads | §2 |
| b | Version gate — accept `0x8B`, learn the BCA bit | §3 |
| c | Ring counts + per-ring `item_type` byte | §4 |
| d | Work-item formats (ACWI/CWI) — *deferrable*, negotiate legacy WI64 | §5 |
| e | HME (Host Memory Extension) — mandatory before link | §6 |
| f | Doorbell register generation | §7 |
| g | HYBRIDFW "LFOC" firmware container + paging | §8 |
| h | D2H SEQNUM sync with livelock guard | §9 |
| i | Per-TID flowrings (deferrable) | §10 |
| j | MLO IPC (WiFi-7, deferrable) | §11 |
| k | Chip IDs for 6717/6726 in chip.c | §1 |

The two largest net-new chunks are **HME (§6)** and the **HYBRIDFW loader (§8)**.

---

## 1. Chip / device identity

- PCI alias: `pci:v000014E4d*sv*sd*bc02sc80i*` → vendor **0x14E4**, **class 0x028000**
  (base 0x02 network, sub 0x80), **any devid**. dhd matches by class
  (mask `0x00ffff00`), not devid. **[RE-CONFIRMED]**
- Firmware ucode tags in dhd.ko: `merlin7_pcieg3_6717_ucode_image`,
  `merlin16_pcieg3_6726_ucode_image`, plus refs to `6715`, `43684`. **[RE-CONFIRMED]**
- Dongle core = **ARM Cortex-A7** (`BCMA_CORE_ARM_CA7`). brcmfmac already has CA7
  support: `brcmf_chip_ca7_set_passive()` (halt) and
  `brcmf_chip_ca7_set_active(chip, rstvec)` (release at reset vector). **[RE-CONFIRMED]**
- `chip.c` has **no** 6717/6726/6715/43684 chip IDs. New `BRCM_CC_*_CHIP_ID`
  cases + core-table entries are required (see prototype patches 0001/0003). **[RE-CONFIRMED]**

**[DYN]** the exact chipcommon chipid register values for 6717a0/6726b0 (read
chipc `0x00` over BAR0 at runtime); the precise CA7 TCM/RAM base + reset-vector
write register for these silicon revs (the `set_active` path exists but is
unverified on this silicon). `devid=0x602d` from nvram is informational only.

### RAM sizing
For CA7, brcmfmac reads rambase/ramsize from `BCMA_CORE_SYS_MEM` (not the
hardcoded CR4 `tcm_rambase` table) — so no new constant is needed *if* the
SYS_MEM core enumerates. dhd confirms a dynamic path: `Adjust dongle RAMSIZE to
0x%x`, module param `dhd_dongle_ramsize`, and a `SMAR` ramsize tag
(`0x534D4152` = brcmfmac's `BRCMF_RAMSIZE_MAGIC`, honored by
`brcmf_pcie_adjust_ramsize`). **[RE-CONFIRMED]**

---

## 2. Shared-memory struct: `pcie_ipc_t` (128 B, dongle TCM) [SDK]

Discovered via the legacy shared-RAM pointer at the end of TCM (the same
discovery path brcmfmac uses — see §8 step 5). All fields little-endian;
`daddr32_t` = u32 dongle address, `haddr64_t` = 8-byte host physical address.
Layout from bcmpcie.h:897-990:

```
off   field                       notes
0x00  uint32  flags               bits[7:0] = IPC revision (0x8B); flag bits below
0x04  daddr32 trap_daddr32
0x08  daddr32 assert_exp_daddr32
0x0C  daddr32 assert_file_daddr32
0x10  uint32  assert_line
0x14  daddr32 console_daddr32      -> hnd_cons_t
0x18  uint32  msgtrace/btrace_daddr32
0x1C  uint32  fwid                 <-- rtecdc_fwid handshake (§3)
0x20  uint16  max_tx_pkts; uint16 max_rx_pkts
0x24  uint32  dma_rxoffset
0x28  daddr32 h2d_mb_daddr32       <-- H2D mailbox (doorbell data, §7a)
0x2C  daddr32 d2h_mb_daddr32       <-- D2H mailbox
0x30  daddr32 rings_daddr32        <-- pcie_ipc_rings_t (§4)
0x34  uint32  host_mem_len         HME total bytes (host-filled, §6)
0x38  haddr64 host_mem_haddr64     HME per-user phys-addr table (host-filled)
0x40  uint16  host_mem_users       HME user count (dongle-filled)
0x42  uint16  host_mem_size        sizeof pcie_ipc_hme_t (dongle-filled)
0x44  uint32  host_mem_daddr32     -> pcie_ipc_hme_t (dongle-filled, §6)
0x48  uint8   max_rch_sdu_cnt; uint8 PAD[3]
0x4C  daddr32 buzzz_daddr32
      --- end Rev5 region: PCIE_IPC_REV5_SZ = 0x50 (80 B) ---
0x50  uint32  dcap1                dongle capabilities-1 (§5/§6)
0x54  uint32  dcap2                dongle capabilities-2
0x58  uint32  hcap1                host ack caps-1 (host writes, §3/§6)
0x5C  uint32  hcap2                host ack caps-2 (host writes)
0x60  uint32  host_physaddrhi      fixed hi32 for CWI32 addressing
0x64  union { fatal_logbuf_daddr32 | cpudbg_* | ucls_*/hmo_event_* (rev 0x8a) } [7 words]
      --- total sizeof(pcie_ipc_t) = PCIE_IPC_SZ = 0x80 (128 B) ---
```
`PCIE_IPC_REV5_SZ = OFFSETOF(__post_rev5_extn) = 80`.

### `flags` bitfield (bcmpcie.h:163-180) [SDK]; DMA/sync bits [RE-CONFIRMED via dhd strings]
```
[7:0]      revision (0x8B)
0x00000100 ASSERT_BUILT      0x00000200 ASSERT       0x00000400 TRAP
0x00010000 DMA_INDEX         dongle DMAs RD/WR index arrays to host
0x00020000 D2H_SYNC_SEQNUM   ("D2H SYNC: SEQNUM:" in dhd.ko)
0x00040000 D2H_SYNC_XORCSUM  ("D2H SYNC: XORCSUM:" in dhd.ko)
0x00080000 IDLE_FLOW_RING
0x00100000 2BYTE_INDICES     16-bit RD/WR indices
0x00200000 DHDHDR (host LLCSNAP)    0x00400000 MAC_D11TOD3
0x00800000 NO_TXPOST_CWI32   force legacy WI64 instead of CWI32 (see §5)
0x10000000 HOSTRDY_SUPPORT   host-ready via PCIH2D_DB1
D2H_SYNC_MODE_MASK = SEQNUM | XORCSUM (bcmpcie.h:183)
```

---

## 3. Two-gate handshake: IPC revision + rtecdc_fwid [RE-CONFIRMED]

The back-end must satisfy two independent gates after the dongle boots.

**Gate 1 — IPC revision (HARD; this is the porting blocker):**
- Host writes `hcap1[7:0]` = host IPC revision
  (`PCIE_IPC_HCAP1_REVISION_MASK 0x000000FF`, bcmpcie.h:226). Default host
  revision `PCIE_IPC_DEFAULT_HOST_REVISION = 5` (bcmpcie.h:145) — must be raised.
- Dongle advertises `flags[7:0] = 0x8B`.
- BCA macros: `PCIE_IPC_REV_IS_BCA(u32) = (u32 & 0x80)`,
  `PCIE_IPC_VER_GET(u32) = (u32 & 0x7F)` (bcmpcie.h:147-156). The `0x80` BCA bit
  means **"typed-struct layout"** (this spec), not the legacy offset layout.
- Failure strings: `PCIe IPC Revision compatibility: host 0x%02x, dngl 0x%02x`,
  `PCIe IPC REVISION FAILURE: host 0x%02x incompatible with dngl 0x%02x`,
  `###### BCA PCIe IPC REVISION INCOMPATIBLE ###### UPGRADE DHD TO PCIe IPC REV [0x%02x]`,
  `Contents of pcie_ipc_t structure are not matching.` Functions
  `dhdpcie_bus_init_pcie_ipc`, `dhdpcie_bus_read_pcie_ipc`. **[RE-CONFIRMED]**

**Gate 2 — FWID / logstrs (SOFT; datapath-irrelevant):**
- `pcie_ipc::fwid` (off 0x1C) = rtecdc_fwid. dhd cross-checks against host-side
  `logstrs.bin`: `logstr id does not match FW! logstrs_fwid:0x%x, rtecdc_fwid:0x%x`,
  dumps `FWID 0x%08x, flags 0x%08x, dcap1 0x%08x dcap2 0x%08x`. Firmware prints
  `PCIE IPC FWID 0x%08x Rev: host %x dngl %x` and `FWID 01-%x`. **[RE-CONFIRMED]**
- For a brcmfmac port this **only affects firmware-log decode and can be ignored**.
  No `logstrs.bin` / `rtecdc.map` ships on the rootfs anyway. **[RE-CONFIRMED]**

---

## 4. Rings: `pcie_ipc_rings_t` (128 B) [SDK]

Pointed to by `pcie_ipc::rings_daddr32`. Layout from bcmpcie.h:409-475:

```
off   field
0x00  daddr32 ring_mem_daddr32     -> array of pcie_ipc_ring_mem_t (one per ring)
0x04  daddr32 h2d_wr_daddr32       index arrays in dongle TCM…
0x08  daddr32 h2d_rd_daddr32
0x0C  daddr32 d2h_wr_daddr32
0x10  daddr32 d2h_rd_daddr32
0x14  haddr64 h2d_wr_haddr64       …and their host-memory mirrors (DMA_INDEX)
0x1C  haddr64 h2d_rd_haddr64
0x24  haddr64 d2h_wr_haddr64
0x2C  haddr64 d2h_rd_haddr64
0x34  uint16  max_h2d_rings; uint16 max_d2h_rings
      --- PCIE_IPC_RINGS_REV5_SZ = OFFSETOF(__post_rev5_extn) = 0x38 ---
0x38  uint16  max_flowrings; uint16 max_interfaces  (bcmc + ucast split)
0x3C  uint32  wi_formats = { u8 txpost_format; u8 rxpost_format;
                             u8 txcpln_format; u8 rxcpln_format }  <-- §5 selectors
0x40  uint16  rxpost_data_buf_len; uint16 rxcpln_dataoffset
0x44  haddr64 ifrm_wr_haddr64
0x4C  uint32  PAD[13]              -> total 128 B
```

Per-ring descriptor `pcie_ipc_ring_mem_t` (bcmpcie.h:396-404), **16 B**:
```
0x00 uint16 id; 0x02 uint8 type; 0x03 uint8 item_type;
0x04 uint16 max_items; 0x06 uint16 item_size; 0x08 haddr64 haddr64
```

**Delta vs brcmfmac:** stock brcmfmac's ring descriptor uses fixed offsets
`MAX_ITEM_OFFSET=4`, `LEN_ITEMS_OFFSET`, `MEM_BASE_ADDR_OFFSET=8` (pcie.c:168-169)
and has **no `item_type` byte**. The new `pcie_ipc_ring_mem_t.item_type` (offset 3)
selects WI64/CWI/ACWI per-ring; the back-end must populate and honor it. **[SDK + RE-CONFIRMED]**

### Common rings (bcmpcie.h:281-295) — IDs match brcmfmac
```
0 H2D CONTROL_SUBMIT     1 H2D RXPOST_SUBMIT
2 D2H CONTROL_COMPLETE   3 D2H TX_COMPLETE   4 D2H RX_COMPLETE
BCMPCIE_H2D_COMMON_MSGRINGS = 2   BCMPCIE_D2H_COMMON_MSGRINGS = 6
BCMPCIE_COMMON_MSGRINGS = 8       COMMON_MSGRING_MAX_ID = 7
```
**Delta:** stock brcmfmac assumes `D2H_COMMON = 3`. Here it is **6** (room for
HWA RXCPL4 / debug / btlog / pcap completion rings). All index-array sizing math
must use 6, and flowrings start at index `BCMPCIE_H2D_COMMON_MSGRINGS (2)`. **[SDK]**
dhd string `Config : Max Rings H2D %u Flowrings %u D2H %u` confirms the 3-way
ring-count config. **[RE-CONFIRMED]**

### Ring types (bcmpcie.h:300-315) [SDK]
```
H2D types: CTRL_SUBMIT 1  TXFLOW_RING 2  RXBUFPOST 3  TXSUBMIT 4  DBGBUF 5  BTLOG 6  PCAP 7
D2H types: CTRL_CPL 1     TX_CPL 2       RX_CPL 3     DBGBUF_CPL 4 AC_RX_COMPLETE 5 BTLOG_CPL 6 PCAP_CPL 7
BCMPCIE_MAX_TX_FLOWS = 40  (default; may be overridden — §10)
```

---

## 5. Work-item formats (variable ACWI/CWI items) [SDK]

Selector enums (bcmmsgbuf.h:1325-1340): mode `MSGBUF_WI_LEGACY 0 / COMPACT 1 /
AGGREGATE 4`; item_type `WI64 0, CWI32 1, CWI64 2, ACWI32 3, ACWI64 4`. Defaults
`MSGBUF_WI_CWI = CWI32`, `MSGBUF_WI_ACWI = ACWI64`. Negotiated via
`dcap1 ACWI 0x00020000` + `wi_formats` in `pcie_ipc_rings_t`. Empty ACWI slot
sentinel = `HWA_HOST_PKTID_NULL 0x00000000`; `HWA_AGGR_MAX = 4`. **[SDK]** dhd
confirms `H2R_AGGR_CONFIG_NOTIF`. **[RE-CONFIRMED]**

Item sizes (bcmmsgbuf.h:41-51):
```
H2D: TXPOST 48  RXPOST 32  CTRL_SUB 40
D2H: TXCMPLT 16 RXCMPLT 32 CTRL_CMPLT 24
```

Legacy WI64 structs (these are what stock brcmfmac already speaks — use first):
- `host_rxbuf_post_t` 32B: cmn_hdr(8) + metadata_buf_len(2)+data_buf_len(2)+rsvd(4)
  + metadata_buf_haddr64(8) + data_buf_haddr64(8). (bcmmsgbuf.h:855)
- `host_txbuf_post_t` 48B: cmn_hdr(8) + txhdr[ETHER_HDR_LEN=14] + flags(1)+seg_cnt(1)
  + metadata_buf_haddr64(8) + data_buf_haddr64(8) + metadata_buf_len(2)+data_len(2)
  + marker(4). (bcmmsgbuf.h:902)
- `host_rxbuf_cmpl_t` 32B (IPC rev7): cmn_hdr + compl_hdr + metadata_len/data_len/
  data_offset/flags + rx_status_0/1 + marker (marker reserved on rev7). (bcmmsgbuf.h:876)
- `host_txbuf_cmpl_t` 16B: cmn_hdr + compl_hdr + {metadata_len, tx_status} union marker. (bcmmsgbuf.h:952)

Compact HWA-2.0 items (rev8+, only for HWA offload — defer):
- `hwa_rxpost_cwi32` 8B {host_pktid; data_buf_haddr32}; `cwi64` 16B; `acwi32` 32B;
  `acwi64` 48B (bcmmsgbuf.h:1374-1429).
- `hwa_txpost_cwi32` 28B / `cwi64` 32B with bitfields {ifid:5, prio:3, copy:1,
  flags:7}, data_buf_hlen, eth_sada[12], eth_type, flowid_override:12 (bcmmsgbuf.h:1443-1517).
- `hwa_rxcple_cwi` 8B; `hwa_rxcple_acwi` = array[4] of cwi (bcmmsgbuf.h:1549-1593).

**Minimal-port strategy:** negotiate `wi_formats = WI64 (0)` for all four
directions and advertise **no** `dcap1 ACWI`, so the dongle uses the legacy
48/32/16/32 items brcmfmac already implements. The
`PCIE_IPC_FLAGS_NO_TXPOST_CWI32 (0x00800000)` flag confirms legacy fallback is
supported. **[DYN]** confirm this FW build honors WI64 when it is ACWI-capable.

---

## 6. HME — Host Memory Extension (MANDATORY before link) [SDK + RE-CONFIRMED]

No equivalent exists in brcmfmac; without it the dongle will not link. dhd strings:
`PCIe IPC MEMORY FAILURE: malloc %u bytes. [pcie_ipc_hme users %u]`,
`BCM Host Memory Extension Service … ver %u users %u size %u`; symbols
`dhd_hme_buf_alloc / dhd_hme_buf_free`. **[RE-CONFIRMED]**

Handshake (bcmpcie.h:760-809):
1. Dongle advertises HME capability via `dcap1 HOST_MEM_EXTN 0x00080000`; host
   acks the same bit in `hcap1`.
2. Dongle fills `pcie_ipc_hme_t` (located via `host_mem_daddr32`):
   `{ u8 version; u8 users; u16 size; u32 bytes; haddr64 haddr64; pcie_ipc_hme_user_t user[] }`.
3. Each `pcie_ipc_hme_user_t` (32 B):
   `{ u8 user_id; u8 align_bits; u8 bound_bits; u8 sgmt_avail; u16 flags; u16 pages; char name[8] } + { u32 bhm_offset; u32 PAD[3] }`.
4. Host allocates a DMA buffer per user (4 KB pages, `PCIE_IPC_HME_PAGE_SIZE`),
   builds a haddr64 table, then writes `host_mem_haddr64` (0x38) + `host_mem_len` (0x34).

User IDs (bcmpcie.h:675-697):
`0 SCRMEM  1 PKTPGR  2 MACIFS  …  6 HMOSWP (HYBRIDFW)  …  19 MLOIPC`.
Flags (bcmpcie.h:727-735):
`HYBRIDFW / PRIVATE / ALIGNED / BOUNDARY / SBTOPCIE / DMA_XFER / BHM / SGMT`. **[SDK]**

**Critical sub-case — HYBRIDFW (couples to §8):** the user `HMOSWP`
(= `PCIE_IPC_HYBRIDFW_HME_USER`) must be allocated **before** the link phase.
The host copies the host-resident firmware segment into that region and writes a
`host_location_info_t` r-TLV (`{ addr_lo, addr_hi, binary_size, tlv_size,
tlv_signature }`) at a well-known top-of-TCM location. **[SDK]**

---

## 7. Doorbell / mailbox mechanism [SDK + RE-CONFIRMED]

Two layers.

### 7a. Mailbox DATA words
`pcie_ipc::h2d_mb_daddr32` (0x28) / `d2h_mb_daddr32` (0x2C), plus inband
`MSG_TYPE_H2D_MAILBOX_DATA (0x23)` / `MSG_TYPE_D2H_MAILBOX_DATA (0x24)` via the
control ring (`h2d_mailbox_data_t` / `d2h_mailbox_data_t`, bcmmsgbuf.h:512,757).

H2DMB bits (bcmpcie.h:1011-1041) — dhd strings confirm each is sent **[RE-CONFIRMED]**:
```
0x00000001 HOST_D3_INFORM   0x00000002 DS_ACK   0x00000004 DS_NAK
0x00000008 HOST_D0_INFORM_IN_USE   0x00000010 HOST_D0_INFORM
0x00000020 DS_ACTIVE   0x00000040 DS_DEVICE_WAKE   0x00000080 HOST_IDMA_INITED
0x00000100 MLC_BIND 0x00000200 MLC_LINK 0x00000400 MLC_BRIDGE 0x00000800 MLC_SYNC
0x00001000 MLC_READY 0x00002000 MLC_HALT 0x00004000 MLC_SUSPEND 0x00008000 MLC_SUSPEND_HALT
0x10000000 HOST_ACK_NOINT  0x20000000 FW_TRAP  0x80000000 HOST_CONS_INT
```
D2HMB bits (bcmpcie.h:1044-1071):
`0x00000001 DEV_D3_ACK … 0x10000000 DEV_FWHALT, 0x20000000 EXT_TRAP_DATA,
FWTRAP_MASK 0x1F`, plus the MLC_* states 0x100–0x80000.

The single most important H2DMB to send after ring/HME negotiation is
`PCIE_IPC_H2DMB_HOST_D0_INFORM (0x10)`.

### 7b. Hardware doorbell registers
dhd symbols `dhd_bus_ringbell`, `dhd_bus_ringbell_2`, `dhd_bus_ringbell_oldpcie`,
`dhd_bus_db1_ringbell_2` reveal two doorbell-register generations; 6717/6726 use
the newer (`_2`) path. `HOSTRDY_SUPPORT (flags 0x10000000)` → host-ready via DB1.
**[RE-CONFIRMED]**

**[DYN]** the exact BAR0 doorbell register offsets for 6717a0/6726b0
(PCIH2D_DB0/DB1, and the DAR variant if `dcap1 DAR 0x80000000`) are **not** in
bcmpcie.h — read from impl103 `pcie_core.h` or derive at runtime. brcmfmac's
hardcoded `BRCMF_PCIE_*_DB` offsets are likely wrong for this generation and must
be verified.

---

## 8. Firmware container — `rtecdc.bin` is HYBRIDFW "LFOC", not a flat blob [RE-CONFIRMED]

Both images begin with magic **`LFOC`** = bytes `4C 46 4F 43` = LE `0x434F464C` =
`PCIE_IPC_HYBRIDFW_MAGICNUM` ('C','O','F','L', bcmpcie.h:885). This is the
decisive firmware-loading delta. **[RE-CONFIRMED]**

### 8a. LFOC header — decoded (12 bytes, then the loadable ARM image)
```
off   6717a0          6726b0          meaning
0x00  4C 46 4F 43     same            magic (LE u32 0x434F464C, "LFOC")
0x04  0x00000000      0x00000000      flags/version (0 = uncompressed raw image)
0x08  0x001F4004      0x0024B004      size/region-length field (see 8b)
0x0C  0xB818F001      0xB818F001      FIRST IMAGE WORD = reset vector (Thumb-2 B.W)
```
File sizes: 6717a0 = **4,091,928 B** (0x3E7018); 6726b0 = **5,365,784 B** (0x51E018).

The bytes from **0x0C onward are the ARM Cortex-A7 (Thumb-2) image**, and 0x0C is
the start of the exception-vector table:
- 0x0C reset → `B.W 0x1040` (`_start` / `c_main`)
- 0x10 undef, 0x14 SWI, 0x18 prefetch-abort, 0x1C data-abort, 0x20 IRQ → all
  `B.W` into the 0x2Dxx handler region; vector slots `0xFA`-padded to 0x78, then BSS-zero.

Therefore:
- **loadable image** = `rtecdc.bin[0x0C:]`
- **reset/entry vector** = `le32(rtecdc.bin[0x0C])` — **NOT** `le32(rtecdc.bin[0])`
  (byte 0 is "LFOC"). **[RE-CONFIRMED via Thumb-2 decode]**

### 8b. size@0x08 (partially known)
6717a0 = 0x1F4004 (2,048,004) ≈ half the file; 6726b0 = 0x24B004 (2,461,700) ≈ half.
The image is **contiguous** (single LFOC, no second magic). Just before
`0x0C + size` there is a ~407 KB zero run (.bss); code resumes after, so the field
is **not** a clean code/data split and **not** the file length. Best
interpretation: a length/checksummed-region used by dhd's own integrity/membytes
loop. For a brcmfmac-style "memcpy whole image to rambase" load it is **not
needed**. **[RE-CONFIRMED bytes; exact field meaning DYN — needs rtecdc.map / dhd disasm].**

### 8c. HYBRIDFW paging (the host-resident split)
Stock brcmfmac `firmware.c` downloads a flat image to TCM base and jumps. Here the
image is split: a **dongle-resident** portion (download to TCM) + a
**host-resident** portion the dongle pages on demand from an HME region via MMU
(`SW_PAGING` / HYBRIDFW). The back-end must: parse the LFOC header, set up the
`HMOSWP` HME region (§6), copy the host-resident part there, and publish
`host_location_info_t`. `PCIE_IPC_HYBRIDFW_TYPE_DNGL = 0`,
`PCIE_IPC_HYBRIDFW_TYPE_HOST = 1` (bcmpcie.h:886). **[SDK]**

**[DYN]** whether SW_PAGING can be disabled (whole image to TCM) for 6717/6726 —
almost certainly **not**, given the ~4–5 MB image vs TCM size; paging is likely
mandatory. A first bring-up should assume paging is required.

### 8d. CLM is embedded (no separate `.clm_blob`)
CLM lives **inside** the image. Marker `"CLM DATA\0Broadcom-0.0\0"` at file offset
**0xA327F** (6717a0) / **0xB2A3F** (6726b0); the populated blob header
(`…BE98_20240925…1.69.0…`) at **0xA40E8** / **0xB3A68**. CLM version `1.69.0`,
brand-tag `BE98_20240925`; TX-limit tables (`TXLO…`) from ~0x3838xx to near EOF.
**The host does NOT supply a `.clm_blob` and does NOT `wl clmload`** — firmware
self-applies CLM at init using nvram `ccode`/`regrev`. (Contrast: SoftMAC wl.ko
loads CLM separately.) **[RE-CONFIRMED]**

### 8e. nvram (`GT-BE98.nvm`) format
Plain text, space/newline-separated `key=value`, two key kinds:
- **devpath aliases:** `devpath1=pcie/0/1/`, plus `1:devpathN=sb/1/` band-index forms.
- **indexed:** `N:key=value` where N is the wl-unit/band, e.g.
  `1:sromrev=19 1:boardrev=0x1104 1:boardtype=0xa5e 1:devid=0x602d
  1:macaddr=20:CF:30:00:00:0C 1:ccode=US …` (full PHY cal: txchain/rxchain,
  femctrl, tempthresh, pdoffset*, rxgainerr*, …).

Host-side requirements (dhd strings): nvram is appended to the dongle as a text
blob and **must be terminated with double-NUL** (`Nvram was not terminated with
double zeroes.`); dhd logs `%s external nvram %d bytes` plus a trailing length word.
brcmfmac's `brcmf_init_nvram_parser` + `brcmf_fw_strip_multi_v1` already strip
comments, pack `key=val\0`, double-NUL terminate, and match `devpath%d=` against
the PCI path (`pcie/0/1`) to pick the per-device index — **so the GT-BE98.nvm
prefix scheme is compatible with the existing parser.** Keep the `N:` band-index
prefixes verbatim (firmware resolves them). **[RE-CONFIRMED; N:-prefix tolerance DYN, low-risk]**

---

## 9. D2H sync — consume completions safely [SDK + RE-CONFIRMED]

dhd implements three modes (symbols `dhd_prot_d2h_sync_none / _seqnum /
_xorcsum`; livelock handler `dhd_prot_d2h_sync_livelock`). Mode is selected by
`flags` bits `D2H_SYNC_SEQNUM (0x20000)` / `D2H_SYNC_XORCSUM (0x40000)`. **[RE-CONFIRMED]**

- **SEQNUM:** every D2H work item's `cmn_msg_hdr_t.epoch` (bcmmsgbuf.h:140, offset
  3) carries a mod-253 sequence (`D2H_EPOCH_MODULO 253`, `INIT_VAL 254`). Host
  spins reading the item until `epoch` reaches the expected value; mismatch →
  retry to a max, else **LIVELOCK** (`LIVELOCK DHD<%p> seqnum<%u:%u> tries<%u>…`,
  `gap between prev seqnum %u & curr seqnum %u`). **[RE-CONFIRMED]**
- **XORCSUM:** the trailing `dma_done_t marker` (u32, last field of every
  completion struct) is an XOR checksum over the item; host recomputes and waits
  until it matches. **[SDK + RE-CONFIRMED]**

**Delta vs brcmfmac:** stock brcmfmac uses the simpler `MSGBUF_*` consume with the
`dma_done` write-complete marker but does **not** implement the mod-253 epoch
livelock loop. The back-end should read the negotiated mode from `flags` and
implement the **SEQNUM** path (this FW build advertises the SEQNUM string). The
H2D direction also uses an epoch (`H2D_EPOCH_MODULO 253`). **[SDK]**

---

## 10. Flowrings — dynamic, per-TID [SDK + RE-CONFIRMED]

- Create/delete/flush use the **same control-ring messages** as brcmfmac:
  `tx_flowring_create_request_t` (bcmmsgbuf.h:414, 40B: da[6], sa[6], tid,
  **item_type**, flow_ring_id, tc, priority_ifrmmask, int_vector, max_items,
  len_item, haddr64). Note the **new `item_type` byte** (per-flowring WI64/CWI/ACWI
  selector) and `priority_ifrmmask` (IFRM core mask) vs brcmfmac's older request. **[SDK]**
- Response `ring_create_response_t` (bcmmsgbuf.h:704) = cmn_hdr +
  compl_hdr{ int16 status; uint16 ring_id } + rsvd[2] + marker; dhd symbols
  `dhd_bus_flow_ring_create_request/response`, `dhd_prot_flow_ring_create`. **[RE-CONFIRMED]**
- **Per-TID flowrings:** `dcap1 FLOWRING_TID 0x00800000` (bcmpcie.h:198). dhd
  strings `Config : Flowring per TID`, `dhd_idma_flowmgr_*`,
  `dhd_get_flowid/dhd_add_flowid/dhd_del_flowid`, `dhd_flow_rings_ifindex2role`.
  A single peer can have one flowring **per TID** (vs brcmfmac's per-(if,da,prio)
  single flowring). `BCMPCIE_MAX_TX_FLOWS = 40` default, extended at runtime. **[RE-CONFIRMED]**
- Status codes `BCMPCIE_SUCCESS..14` (bcmmsgbuf.h:603-617) match brcmfmac.

**[DYN]** exact max flowrings for this FW (read `pcie_ipc_rings::max_flowrings`).
Per-TID flowrings are **deferrable** for first bring-up — use the brcmfmac
single-flowring model initially.

---

## 11. MLO IPC — WiFi-7 multi-link (deferrable) [RE-CONFIRMED]

dhd has a full `dhd_mlo_ipc_*` subsystem (init/start/deinit,
`dhd_mlo_ipc_process_dongle_event`, `dhd_mlo_ipc_wlioctl_intercept`, HME user
`MLOIPC = 19`, H2DMB/D2HMB `MLC_*` states BIND→LINK→BRIDGE→SYNC→READY→ACTIVE).
**Not required for single-link bring-up.** brcmfmac has zero MLO. This is the
eventual path to real WiFi-7 MLO. **[RE-CONFIRMED for the state machine; full semantics DYN]**

---

## 12. End-to-end firmware-load sequence (dhd, protocol level) [RE-CONFIRMED]

From dhd.ko `_dhdpcie_download_firmware` / `dhd_bus_download_firmware`:

1. Map BAR0 (backplane window) + BAR1 (TCM). Enumerate cores via EROM; find CA7 +
   SYS_MEM; compute ramsize (honor `SMAR 0x534D4152` tag / `dhd_dongle_ramsize`).
2. **Halt CA7** (`ca7_set_passive`) — enter download state.
3. **membytes write** the image to dongle RAM at rambase
   (`membytes FAILED`, `error on %s membytes, addr … size`). Then write the nvram
   text blob high in RAM, double-NUL terminated, with trailing length word.
4. **Release CA7 at the reset vector** (`ca7_set_active(resetvec)`), resetvec =
   `le32(rtecdc.bin[0x0C])` (§8a).
5. **Training:** `PCIe IPC Host Dongle Training Commences …`. Host locates the IPC
   shared struct via the legacy end-of-TCM pointer:
   `PCIe IPC LOCATED: read_u32 daddr32 0x%08x … ram[0x%08x,0x%08x]`; validates
   `PCIe IPC address (0x%08x) invalid` / `daddr32 … invalid`.
6. **Two-gate handshake (§3):** revision (`hcap1[7:0]` host rev vs dongle `0x8B`)
   + optional FWID/logstrs.
7. **Negotiate** rings (§4), HME (§6), DMA indices (msgbuf); send
   `PCIE_IPC_H2DMB_HOST_D0_INFORM`. Runner/flowring offload is **OPTIONAL**:
   `Force disabling Runner Offload for RX/TX` → a pure software datapath works. **[RE-CONFIRMED]**

---

## 13. Implementation plan — ordered work items for the back-end

Re-using the in-tree msgbuf upper layer is viable (opcodes, status codes,
control/flowring messages, and legacy WI64 item layouts are compatible). Ordered
work items, all **[RE-CONFIRMED]** as blockers unless noted:

1. **Version gate (§3, §2):** accept rev `0x8B`; teach the BCA bit ⇒ parse the
   typed `pcie_ipc_t` / `pcie_ipc_rings_t` instead of brcmfmac's offset reads.
   Raise `BRCMF_PCIE_MAX_SHARED_VERSION` to ≥0x0B and branch on `flags & 0x80`.
2. **Ring counts (§4):** `D2H_COMMON = 6`, `COMMON = 8`; honor the per-ring
   `item_type` byte.
3. **HME (§6):** implement the host-memory-extension allocator + per-user table —
   mandatory before link.
4. **HYBRIDFW loader (§8):** parse `LFOC`, strip the 12-byte header (payload =
   `rtecdc[0x0C:]`, resetvec = `le32(rtecdc[0x0C])`), set up the `HMOSWP` HME
   region + `host_location_info_t`. (§3+§4 are largest net-new chunks with HME.)
5. **D2H SEQNUM sync (§9)** with the livelock guard.
6. **Doorbell registers (§7b)** for the newer PCIe gen — **[DYN]**, read impl103
   `pcie_core.h` or derive at runtime; verify brcmfmac's `BRCMF_PCIE_*_DB`.
7. **Chip IDs (§1)** for 6717/6726 (/6715/43684) in chip.c — **[DYN]** chipid values.
8. **Negotiate WI64 legacy mode (§5)** to avoid implementing ACWI/CWI initially;
   **defer** HWA, MLO (§11), and per-TID flowrings (§10).

### firmware.c / pcie.c edit sketch
```
LFOC-strip:    payload  = rtecdc[0x0C:]                 // drop 12-byte header
               resetvec = le32(rtecdc[0x0C])            // NOT le32(rtecdc[0])
               // brcmf_pcie_download_fw_nvram: change
               //   resetintr = get_unaligned_le32(fw->data)
               //   -> get_unaligned_le32(fw->data + 0x0C); skip 0x0C on memcpy
CLM-carve:     NONE — CLM is embedded (§8d); do not request/append a .clm_blob.
nvram-convert: feed GT-BE98.nvm through brcmf_init_nvram_parser (already strips
               comments, packs key=val\0, double-NUL terminates); keep devpath%d=
               matching "pcie/0/1"; keep "N:" prefixes verbatim; append length word.
download:      ca7_set_passive -> memcpy_toio(rambase, payload)
               -> write nvram high in RAM -> ca7_set_active(resetvec)
               -> poll end-of-TCM for the IPC pointer.
identity:      add vendor 0x14e4 + (devid table OR class 0x028000/mask 0x00ffff00);
               CA7 ramsize via SYS_MEM core + honor SMAR (0x534d4152) tag.
BLOCKER:       replace pcie_shared v5-7 handshake + msgbuf init with the PcIe-IPC
               struct / FWID-rev / HME negotiation (§2,§3,§6). NOT solvable by
               firmware.c alone.
```

### Authoritative coding sources
- Struct/define source: impl103 `bcmpcie.h` and `bcmmsgbuf.h` (the exact headers
  dhd.ko was compiled from — every offset in this SPEC is from them).
- brcmfmac target: `brcm80211/brcmfmac/{pcie.c, chip.c, firmware.c, msgbuf.c}`.

### Remaining [DYN] items (need bench / impl103 pcie_core.h / dhd disasm)
- chipcommon chipid values for 6717a0/6726b0; CA7 TCM/RAM base + reset-vector
  write register for these silicon revs.
- doorbell register offsets (PCIH2D_DB0/DB1, DAR variant).
- whether legacy-WI64 / no-paging can be forced; size@0x08 exact semantics.
- whether the firmware tolerates the `N:`-prefixed nvram exactly as brcmfmac emits it.

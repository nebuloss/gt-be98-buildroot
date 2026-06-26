# HME bit6 / hcap<1> publish mechanism — BCM6726b0 (dhd.ko host RE + ram.elf dongle)

Resolves: how dhd makes the dongle mark each BHM HME user "iDMA-eligible" (per-user
flags bit6 / 0x40), so the dongle prints `hcap<1>` instead of "Host does not support iDMA".

## VERDICT (one line)
**The host does NOT publish per-user bit6. bit6 is set BY THE DONGLE inside its HME-user
descriptor, gated on a host capability word the host writes BEFORE bind. The host's only
job is to advertise the iDMA host-cap bit in the published `pcie_ipc` caps; the dongle
then sets bit6 per BHM user and echoes it as `hcap<1>`.** Our open driver never advertises
that cap (`hcap2 = 0`; `BCA_HCAP_IDMA64_PLACEHOLDER = 0x00000000` is still a TODO), so the
dongle sets bit6 on no BHM user and refuses iDMA.

## 1. dhd.ko (host) — what the host actually publishes (DECISIVE)
`dhd_bus_cmn_writeshared` (Ghidra **0x1505b0**) is the *complete* enumerated set of host
writes into the dongle's `pcie_ipc` (base = `bus+0x2f0`). Every HME/cap field:
- case 0  -> `+0x38` `host_mem_haddr64`  (**8 bytes** — the flat haddr64 table pointer)
- case 1  -> `+0x34` `host_mem_len`      (4B)
- case 0x1a-> `+0x40` `host_mem_users`   (2B)
- case 0x17-> `+0x58` `hcap1`            (4B)
- case 0x18-> `+0x5c` `hcap2`            (4B)

There is **no 32-byte host-published per-user table and no host-published per-user flags
array.** The host publishes exactly what we publish: one 8-byte haddr64 per user. **Our
8-byte table format is correct — it is NOT the wrong layout.** (Hypotheses (a) and (b) in
the question are both FALSE; the answer is (c): the dongle derives bit6 from a host cap.)

The "32-byte/user, users 23 size 752" structure is the **dongle-published** descriptor
(`pcie_ipc_hme_user`, stride = `bus+0x3c` = **0x20** for rev>=0x8b), which dhd *reads*:
- `dhd_prot_hme_init` (Ghidra **0x140db0**): per user reads dongle desc `+4` flags,
  `(flags>>6 & 1)` = bit6 -> translate addr through the iDMA window `prot+0x3468/0x3470/0x3474`
  (only if `prot+0x34a1` host-iDMA-enable byte is set). It WRITES the 8-byte haddr64
  (`hme_table[u*8] = puVar10[1]`). It never writes bit6.
- `dhdpcie_bus_read_pcie_ipc` (Ghidra **0x14b450**): copies the dongle desc block in
  (`dhdpcie_bus_membytes(.., param_3[0x11], desc, size)`), scans `(*(u16*)(desc+u*0x20+0x14)>>6 & 1)`
  and only sets its own `bus+0x694=1`. It sets `bus+0x34a1=1` purely on dongle rev>=0x8b
  (already satisfied by us). **Neither path ORs 0x40 into any host-published structure.**

Conclusion: bit6 is **read** by dhd from the dongle, never written. So bit6 originates in
the dongle and must be gated by something the host advertised earlier = the cap word.

## 2. ram.elf (dongle) — where bit6 / hcap<1> is produced
The producer is the `hme_link_pcie_ipc` chain (run from DB1 handler
`pciedev_handler_dev0_db1`, dispatch table @ Ghidra 0x103250 / VA 0xf3250). It prints
`HME LINK PCIE IPC dcap<%u> hcap<%u>` (fmt @ Ghidra 0x85f55) and "Host does not support
iDMA" (Ghidra 0x88c65). **These strings are loaded via a runtime-computed base+offset
pointer**, so neither Ghidra nor r2 resolves an xref to the gate function (confirmed: all
`get_xrefs_to`/`axt`/byte-literal searches for these addresses return empty). The exact
AND-mask the dongle applies to the host cap therefore **could not be read statically** —
this is the one residual gap. What IS established: `hcap<%u>` is a per-HME-link nibble (a
`%u`, value 1 in the working dhd trace `05-dhd-nowifi-uncontended-kmsg.log:882`), derived
from the host-published cap; when it is 0 the dongle prints "Host does not support iDMA"
and sets bit6 on no BHM user.

## 3. Net concrete change to the open driver
The change is NOT in `bca_hme.c` (its 8-byte table is correct). It is in the **hcap
publish** — `bca_ipc_handshake()` in `driver/bca_tcm.c` (writes `hcap1` @ ipc+0x58) and the
host-IPC-fields publish that writes `hcap2` @ ipc+0x5c (currently never written -> 0):
- **Advertise the host iDMA64 cap bit** so the dongle's `hme_link` sets per-user bit6 on the
  BHM users. Define `BCA_HCAP_IDMA64` (replace the `0x00000000` placeholder in
  `bca_pcie_ipc.h:67`) and OR it into the published caps. Best-supported candidate, pending
  the live confirmation below: set it in **hcap2** (ipc+0x5c), which we currently leave 0.
  (`hcap1` already carries DMA_INDEX 0x10000 + 2BYTE 0x100000; DMA-index alone selects
  DMA-index mode but NOT iDMA — IDMA-LINK-SPEC §2b.)
- Per-user bit6 is then emitted by the dongle automatically; do not try to write it.

## Confidence
- §1 host-side (no host-published per-user flags; 8-byte table is correct; dhd reads not
  writes bit6): **HIGH** — clean decompiles of named, unstripped dhd functions, all cited.
- §3 "fix = advertise an iDMA64 host-cap bit, most likely in hcap2": **MEDIUM** — the exact
  bit value/word is the only unread piece (dongle string-xref dead-end, §2).

## FALSIFICATION / next step to close the exact bit
Definitive, cheap test on the bench (admin@10.0.0.8):
1. Boot the working dhd on this silicon and dump `pcie_ipc.hcap1` (ipc+0x58) and `hcap2`
   (ipc+0x5c) at the moment of `HME LINK ... hcap<1>`. Diff vs our published hcap1=0x1019008b,
   hcap2=0. The set bit(s) dhd has that we don't ARE the iDMA64 host-cap bit.
2. Set exactly that bit (`BCA_HCAP_IDMA64`) in our publish and re-insmod. PASS = dongle
   prints `hcap<1>` and bit6 appears on the BHM users (SCRMEM flags 0x74 not 0x34).
   FAIL (still hcap<0>) = the gate is not a single published bit; fall back to single-stepping
   the dongle `hme_link` (JTAG) to read the AND-mask directly.

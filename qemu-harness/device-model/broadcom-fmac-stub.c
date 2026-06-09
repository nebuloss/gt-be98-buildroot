/*
 * broadcom-fmac-stub: minimal QEMU PCI device-model emulating the
 * Broadcom BCM6717/6726-class FullMAC WiFi dongle as seen by ASUS's
 * closed dhd.ko (FullMAC host driver) and by upstream brcmfmac.
 *
 * GOAL (Approach A, dynamic-RE harness for the GT-BE98 open-OS effort):
 *   Boot the rebuilt 4.19.294 aarch64 kernel under `qemu-system-aarch64 -M virt`,
 *   present a PCI function matching dhd's alias
 *       pci:v000014E4d*sv*sd*bc02sc80i*   (vendor 0x14e4, class 0x028000),
 *   and emulate just enough of the chip's host-facing surface to let dhd:
 *     1. match + probe (__pci_register_driver class match),
 *     2. run si_attach() -> read the ChipCommon chipid via the BAR0 backplane
 *        window (we return 0x6717 / rev0 by default),
 *     3. download rtecdc.bin firmware into the TCM (BAR1/2 RAM-backed window),
 *     4. read the "PCIe IPC" shared structure from a fixed TCM offset and begin
 *        the BCA-PCIe-IPC revision/feature handshake + ring setup,
 *   while LOGGING every BAR access, every TCM shared-struct read, and the
 *   doorbell/mailbox traffic. THAT TRACE is the deliverable: it captures the
 *   post-v7 BCA-PCIe-IPC layout that the open brcmfmac driver does not know.
 *
 * The device never reaches a working datapath (there is no real PHY/d11 ucode
 * and the firmware ARM core is not executed). That is expected and fine; the
 * prize is the early handshake trace.
 *
 * Register offsets are taken verbatim from the merlin brcmfmac source
 * (drivers/net/wireless/broadcom/brcm80211/brcmfmac/pcie.c) -- dhd uses the
 * same PCIe-gen2 register block:
 *     BAR0_WINDOW       cfg 0x80   (sliding backplane address window)
 *     BAR0_REG_SIZE     0x1000
 *     INTSTATUS         0x90 / INTMASK 0x94
 *     PCIE2REG_INTMASK  0x24
 *     MAILBOXINT        0x48 / MAILBOXMASK 0x4C
 *     H2D_MAILBOX_0     0x140 / H2D_MAILBOX_1 0x144
 *
 * Build: copy into a QEMU source tree at hw/misc/broadcom-fmac-stub.c, add to
 * hw/misc/meson.build (see qemu-harness/scripts/apply-to-qemu.sh), reconfigure
 * and build. Instantiate with `-device broadcom-fmac-stub` on a machine that
 * has a PCIe host bridge (`-M virt` provides one).
 */

#include "qemu/osdep.h"
#include "qemu/log.h"
#include "qemu/units.h"
#include "qemu/module.h"
#include "exec/memory.h"
#include "hw/pci/pci.h"
#include "hw/pci/pci_device.h"
#include "hw/pci/msi.h"
#include "hw/pci/pcie.h"
#include "hw/qdev-properties.h"
#include "migration/vmstate.h"
#include "qom/object.h"

#define TYPE_BCM_FMAC_STUB "broadcom-fmac-stub"
OBJECT_DECLARE_SIMPLE_TYPE(BcmFmacStubState, BCM_FMAC_STUB)

/* ---- PCI identity (matches dhd alias by vendor + class) ---- */
#define BCM_VENDOR_ID            0x14e4
/* device id is wildcarded in dhd's alias; expose a plausible 6717 part id.
 * dhd matches by class so the exact value is not load-bearing, but a distinct
 * value makes the trace unambiguous and lets brcmfmac id-extension work later. */
#define BCM_DEFAULT_DEVICE_ID    0x6717
#define BCM_CLASS_NETWORK_OTHER  0x0280   /* base 0x02 (network), sub 0x80 (other) */

/* ---- BAR layout ---- */
#define BAR0_SIZE                0x4000          /* >= 0x1000 reg window */
#define TCM_SIZE                 (8 * MiB)       /* dongle RAM window (BAR1/2) */

/* ---- BAR0 register offsets (from brcmfmac pcie.c) ---- */
#define REG_PCIE2_INTMASK        0x24
#define REG_MAILBOXINT           0x48
#define REG_MAILBOXMASK          0x4C
#define REG_INTSTATUS            0x90
#define REG_INTMASK              0x94
#define REG_SBMBX                0x98
#define REG_H2D_MAILBOX_0        0x140
#define REG_H2D_MAILBOX_1        0x144

/* config-space sliding backplane window (like BRCMF_PCIE_BAR0_WINDOW 0x80) */
#define CFG_BAR0_WINDOW          0x80

/* ---- backplane / ChipCommon model ---- */
/* SiliconBackplane enumeration base. RE-CONFIRMED from dhd.ko si_enum_base_pa()
 * (@0x6f960) + the live trace: for devid 0x602d (GT-BE98 6717a0) dhd programs
 * the BAR0 sliding window to backplane 0x28000000 and reads offset 0 = the
 * ChipCommon chipid register.  (The old 0x18000000 was the legacy/SoCI-SB base;
 * the 6717/6726 AI-backplane parts enumerate at 0x28000000.) */
#define CHIPCOMMON_BASE          0x28000000u
#define CHIPCOMMON_CHIPID_OFF    0x00
#define CHIPCOMMON_EROMPTR_OFF   0xfc   /* chipc.eromptr -> backplane addr of EROM */

/* ChipCommon chipid register fields (chipcregs.chipid):
 *   [15:0]  chip id     [19:16] chip rev    [23:20] package option
 *   [27:24] #cores      [31:28] chiptype  (1 = SOCI_AI, the AXI backplane)
 * dhd's si_doattach() requires chiptype==1 (AI) so it runs ai_scan()/EROM walk,
 * and accepts chip id 0x6716 (the 6717 family base) -> internally normalized to
 * 0x6726.  [RE-CONFIRMED from si_doattach disasm @0x70300-0x70338]. */
#define CHIPID_AI_TYPE           (1u << 28)
#define CHIPID_6717_ID           0x6716u
/* backplane address where we expose the synthetic EROM table */
#define EROM_BASE                0x28010000u

/* ---- mailbox / doorbell bits (from brcmfmac pcie.c) ---- */
#define D2H_DEV_D3_ACK           0x00000001
#define MB_INT_D2H_DB            0x0000F000   /* D2H doorbell aggregate */
#define H2D_HOST_D0_INFORM       0x00000010

/*
 * Synthetic AI/DMP EROM table (RE-CONFIRMED grammar from dhd.ko ai_scan @0x616c0,
 * get_erom_ent @0x611e0, get_asd @0x61590):
 *
 *   CIA  (Component-ID entry A): [0]=valid(1) [3:1]=tag(CI=0) [19:8]=cid(12b)
 *        [31:20]=mfg(12b, must be 0x43b = Broadcom).
 *   CIB  (Component-ID entry B): [8:4]=#address-descriptors-of-this-core (w22),
 *        [13:9]=nmw [18:14]=nsw [23:19]=nmp ... (wire/port counts).
 *   ASD  (Address-Space Descriptor): [0]=valid [2:1]=tag(ADDR=2 -> &0x6==0x4)
 *        [3]=is64bit [5:4]=sizetype (0x3=>explicit size word) [7:6]=addrtype
 *        [11:8]=slave-port-id [31:12]=base>>12.
 *   END  terminator = 0x0000000F.
 *
 * Minimal table: one core (ChipCommon, cid 0x800) with a single 4 KiB slave
 * address descriptor at the enum base, then END.  This is enough to confirm
 * ai_scan walks the table and to capture the next core dhd looks for.  A full
 * bring-up table (PCIe2 core, ARM-CA7, SYS_MEM, …) is the next iteration.
 *
 *  CIA  = (mfg 0x43b << 20) | (cid 0x800 << 8) | valid 1   = 0x43b80001
 *  CIB  = (#ASD 1 << 4)     | valid 1                       = 0x00000011
 *  ASD  = (base 0x28000000) | (addrtype 0 << 6) | (sztype 1 << 4)
 *                           | (sp 0 << 8) | (tag ADDR 2 << 1) | valid 1
 *         base>>12 already in high bits -> 0x28000000 | 0x14 | 0x1 = 0x28000015
 *         (sztype 1 => size = 4096 << 1 = 8 KiB region)
 *  END  = 0x0000000F
 */
#define EROM_CIA(mfg, cid)  ((((mfg) & 0xfff) << 20) | (((cid) & 0xfff) << 8) | 1u)
/* CIB: [8:4]=#ASD (w22), [13:9]=nmw (w23 master-wrapper count; ai_scan SKIPS the
 * core if nmw==0, see ai_scan @0x617ac `ands w0,w23,#0x1f; b.eq`), [18:14]=nsw,
 * [23:19]=nmp.  Give nmw=1 so the core is parsed; nsw=nmp=0 so the simple
 * get_asd slave-descriptor path is taken (cmn w_nsw,w_nmp must be 0). */
#define EROM_CIB(nasd, nmw) ((((nmw) & 0x1f) << 9) | (((nasd) & 0x1f) << 4) | 1u)
#define EROM_ASD(base, sp, addrtype, sztype) \
    (((base) & 0xfffff000u) | (((sp) & 0xf) << 8) | (((addrtype) & 0x3) << 6) | \
     (((sztype) & 0x3) << 4) | (2u << 1) | 1u)
#define EROM_END            0x0000000fu

static const uint32_t bcm_erom_table[] = {
    EROM_CIA(0x43b, 0x800),                  /* ChipCommon core, Broadcom mfg */
    EROM_CIB(1, 1),                          /* 1 ASD, 1 master wrapper */
    EROM_ASD(CHIPCOMMON_BASE, 0, 0, 1),      /* 4K@enum-base, slave port 0 */
    EROM_END,
};

/*
 * BCA-PCIe-IPC handshake state.
 *
 * We do NOT yet know the exact binary layout of the dongle's PCIe-IPC shared
 * struct (that is what we are reverse-engineering). So this model starts as a
 * faithful LOGGER and an *iterative* responder:
 *   - It records firmware-download writes into TCM.
 *   - On the "core release" / backplane-reset-deassert write it stamps a
 *     candidate shared struct at SHARED_INFO_TCM_OFFSET with a revision byte we
 *     control, so we can watch which fields dhd validates and how it complains.
 *   - The iteration loop is: run -> read dhd's verbose dyndbg complaint
 *     (e.g. "PCIE IPC address invalid", "LOCATION FAILURE daddr32 ... invalid",
 *     "PCIe IPC Revision compatibility: host 0x%02x, dngl 0x%02x") -> adjust the
 *     candidate values below -> rerun. Every step is captured in the trace.
 */
typedef enum {
    IPC_RESET = 0,        /* dongle held in backplane reset */
    IPC_FW_LOADING,       /* host is writing rtecdc.bin into TCM */
    IPC_CORE_RELEASED,    /* host de-asserted reset; "dongle" booting */
    IPC_SHARED_PUBLISHED, /* candidate shared struct stamped into TCM */
    IPC_TRAINING,         /* host reading shared struct / ring setup */
} IpcState;

/* Candidate "PCIe IPC" parameters. Tunable from the command line so the
 * iteration loop needs no recompile. Defaults are best-guess placeholders. */
#define DEFAULT_IPC_REV          0x06   /* host's expected rev; tune to dhd's */
#define DEFAULT_RAM_BASE         0x00000000u
#define DEFAULT_RAM_SIZE         (4 * MiB)
/* dhd reads the IPC shared address from a fixed location near top-of-RAM.
 * Broadcom historically stores it at (ramtop - 4). We expose a tunable. */
#define DEFAULT_SHARED_PTR_OFF   (DEFAULT_RAM_SIZE - 4)
#define DEFAULT_SHARED_INFO_OFF  0x00001000u   /* where we stamp the struct */

struct BcmFmacStubState {
    PCIDevice parent_obj;

    MemoryRegion bar0;   /* backplane register window */
    MemoryRegion tcm;    /* dongle RAM window (MMIO, traced); backed by tcm_buf */
    uint8_t     *tcm_buf;/* TCM backing store (firmware + shared struct live here) */

    /* sliding backplane window: which backplane addr BAR0 currently maps */
    uint32_t bar0_window;

    /* register file (subset we model) */
    uint32_t intstatus;
    uint32_t intmask;
    uint32_t mailboxint;
    uint32_t mailboxmask;
    uint32_t pcie2_intmask;
    uint32_t h2d_mailbox_0;
    uint32_t h2d_mailbox_1;

    /* handshake state machine */
    IpcState ipc_state;
    uint64_t fw_bytes_written;     /* count of TCM writes during fw download */
    bool shared_stamped;

    /* tunables (qdev properties) */
    uint32_t prop_chipid;          /* low 16 bits = chip id */
    uint32_t prop_chiprev;
    uint8_t  prop_ipc_rev;
    uint32_t prop_ram_base;
    uint32_t prop_ram_size;
    uint32_t prop_shared_ptr_off;  /* TCM offset holding the shared-struct ptr */
    uint32_t prop_shared_info_off; /* TCM offset of the shared struct itself */
};

#define TRACE(s, fmt, ...) \
    qemu_log("bcm-fmac-stub: " fmt "\n", ## __VA_ARGS__)

/* ---- backplane (BAR0) read: serve ChipCommon chipid so si_attach proceeds ---- */
static uint64_t bcm_bar0_read(void *opaque, hwaddr addr, unsigned size)
{
    BcmFmacStubState *s = opaque;
    uint32_t bp = s->bar0_window + (uint32_t)addr;
    uint64_t val = 0;

    /* ChipCommon chipid register (offset 0 of the enum-base ChipCommon core) */
    if (bp == (CHIPCOMMON_BASE + CHIPCOMMON_CHIPID_OFF)) {
        /* [15:0]=id [19:16]=rev [23:20]=pkg [27:24]=#cores [31:28]=chiptype.
         * chiptype MUST be 1 (SOCI_AI) for dhd to run ai_scan(); id 0x6716
         * is the recognized 6717 family base. */
        val = (s->prop_chipid & 0xffff) |
              ((s->prop_chiprev & 0xf) << 16) |
              ((0x0u & 0xf) << 20) |          /* package option 0 */
              ((0x6u & 0xf) << 24) |          /* #cores (informational) */
              CHIPID_AI_TYPE;                 /* chiptype = AI */
        TRACE(s, "BAR0 read CHIPID bp=0x%08x -> 0x%08" PRIx64
                 "  (id=0x%x rev=%u type=AI)  [si_doattach]",
              bp, val, s->prop_chipid & 0xffff, s->prop_chiprev);
        return val;
    }
    /* ChipCommon eromptr: dhd's ai_scan() reads this to find the EROM table,
     * then re-points the BAR0 window at it and walks 32-bit entries. */
    if (bp == (CHIPCOMMON_BASE + CHIPCOMMON_EROMPTR_OFF)) {
        val = EROM_BASE;
        TRACE(s, "BAR0 read EROMPTR bp=0x%08x -> 0x%08" PRIx64 "  [ai_scan]",
              bp, val);
        return val;
    }
    /* Synthetic EROM table: served as sequential 32-bit entries starting at
     * EROM_BASE.  ai_scan()/get_erom_ent() walk this to enumerate cores.
     * Entry index = (bp - EROM_BASE)/4.  See bcm_erom_entry(). */
    if (bp >= EROM_BASE && bp < EROM_BASE + sizeof(bcm_erom_table)) {
        uint32_t idx = (bp - EROM_BASE) >> 2;
        if (idx < (sizeof(bcm_erom_table) / sizeof(bcm_erom_table[0]))) {
            val = bcm_erom_table[idx];
            TRACE(s, "BAR0 read EROM[%u] bp=0x%08x -> 0x%08" PRIx64,
                  idx, bp, val);
            return val;
        }
    }

    switch (addr) {
    case REG_INTSTATUS:    val = s->intstatus;     break;
    case REG_INTMASK:      val = s->intmask;       break;
    case REG_MAILBOXINT:   val = s->mailboxint;    break;
    case REG_MAILBOXMASK:  val = s->mailboxmask;   break;
    case REG_PCIE2_INTMASK:val = s->pcie2_intmask; break;
    default:
        TRACE(s, "BAR0 read  off=0x%03" HWADDR_PRIx
                 " bp=0x%08x size=%u -> 0 (unmodeled)", addr, bp, size);
        return 0;
    }
    TRACE(s, "BAR0 read  off=0x%03" HWADDR_PRIx " -> 0x%08" PRIx64,
          addr, val);
    return val;
}

/* publish a candidate PCIe-IPC shared struct into TCM, so dhd's read_pcie_ipc
 * has something to validate. We deliberately keep it minimal + log it; the
 * iteration loop fills fields as dhd complains. */
static void bcm_publish_shared(BcmFmacStubState *s)
{
    uint32_t ptr_off = s->prop_shared_ptr_off;
    uint32_t info_off = s->prop_shared_info_off;
    uint8_t *tcm = s->tcm_buf;
    if (!tcm) {
        return;
    }

    /* Write the shared-struct pointer at the well-known location dhd reads. */
    if (ptr_off + 4 <= s->prop_ram_size) {
        uint32_t le = cpu_to_le32(s->prop_ram_base + info_off);
        memcpy(tcm + ptr_off, &le, 4);
        TRACE(s, "stamped shared-ptr @TCM[0x%08x] = 0x%08x  (-> info @0x%08x)",
              ptr_off, s->prop_ram_base + info_off, info_off);
    }

    /* Minimal candidate header: a revision byte dhd is expected to read first,
     * plus zeroed flags. Exact layout is unknown -> this is the seed we tune. */
    if (info_off + 8 <= s->prop_ram_size) {
        tcm[info_off + 0] = s->prop_ipc_rev;     /* candidate IPC revision */
        tcm[info_off + 1] = 0x00;
        tcm[info_off + 2] = 0x00;
        tcm[info_off + 3] = 0x00;
        TRACE(s, "stamped IPC shared-info @TCM[0x%08x]: rev=0x%02x flags=0",
              info_off, s->prop_ipc_rev);
    }
    s->shared_stamped = true;
    s->ipc_state = IPC_SHARED_PUBLISHED;
}

static void bcm_raise_d2h(BcmFmacStubState *s, uint32_t bits)
{
    PCIDevice *pdev = PCI_DEVICE(s);
    s->mailboxint |= bits;
    s->intstatus  |= bits;
    if (msi_enabled(pdev)) {
        TRACE(s, "raise MSI (mailboxint=0x%08x)", s->mailboxint);
        msi_notify(pdev, 0);
    } else {
        TRACE(s, "raise INTx (mailboxint=0x%08x)", s->mailboxint);
        pci_set_irq(pdev, 1);
    }
}

static void bcm_bar0_write(void *opaque, hwaddr addr, uint64_t val, unsigned size)
{
    BcmFmacStubState *s = opaque;

    switch (addr) {
    case REG_INTSTATUS:
        TRACE(s, "BAR0 write INTSTATUS  = 0x%08" PRIx64 " (W1C)", val);
        s->intstatus &= ~(uint32_t)val;   /* write-1-to-clear */
        return;
    case REG_INTMASK:
        s->intmask = val;
        TRACE(s, "BAR0 write INTMASK    = 0x%08" PRIx64, val);
        return;
    case REG_MAILBOXINT:
        TRACE(s, "BAR0 write MAILBOXINT = 0x%08" PRIx64 " (W1C)", val);
        s->mailboxint &= ~(uint32_t)val;
        return;
    case REG_MAILBOXMASK:
        s->mailboxmask = val;
        TRACE(s, "BAR0 write MAILBOXMASK= 0x%08" PRIx64, val);
        return;
    case REG_PCIE2_INTMASK:
        s->pcie2_intmask = val;
        TRACE(s, "BAR0 write PCIE2INTMSK= 0x%08" PRIx64, val);
        return;

    case REG_H2D_MAILBOX_0:   /* doorbell 0: host kicked a submit ring */
        s->h2d_mailbox_0 = val;
        TRACE(s, "DOORBELL H2D_MAILBOX_0 <= 0x%08" PRIx64
                 "  (ring kick; state=%d)", val, s->ipc_state);
        /* Acknowledge so dhd's ISR runs and ring init advances. */
        bcm_raise_d2h(s, MB_INT_D2H_DB);
        return;
    case REG_H2D_MAILBOX_1:   /* doorbell 1 (db1 ringbell fast path) */
        s->h2d_mailbox_1 = val;
        TRACE(s, "DOORBELL H2D_MAILBOX_1 <= 0x%08" PRIx64, val);
        bcm_raise_d2h(s, MB_INT_D2H_DB);
        return;
    case REG_SBMBX:
        TRACE(s, "BAR0 write SBMBX      = 0x%08" PRIx64, val);
        if (val & H2D_HOST_D0_INFORM) {
            bcm_raise_d2h(s, D2H_DEV_D3_ACK);
        }
        return;
    default:
        TRACE(s, "BAR0 write off=0x%03" HWADDR_PRIx
                 " = 0x%08" PRIx64 " bp=0x%08x (unmodeled)",
              addr, val, s->bar0_window + (uint32_t)addr);
        return;
    }
}

static const MemoryRegionOps bcm_bar0_ops = {
    .read = bcm_bar0_read,
    .write = bcm_bar0_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .impl = { .min_access_size = 4, .max_access_size = 4 },
};

/* ---- TCM (dongle RAM) access: this is the trace surface ---- */
static uint64_t bcm_tcm_read(void *opaque, hwaddr addr, unsigned size)
{
    BcmFmacStubState *s = opaque;
    uint8_t *tcm = s->tcm_buf;
    uint64_t val = 0;
    if (tcm && addr + size <= TCM_SIZE) {
        memcpy(&val, tcm + addr, size);
    }

    /* Flag reads near the shared-struct pointer / shared-info: the prize. */
    if (addr == s->prop_shared_ptr_off) {
        TRACE(s, "*** TCM read SHARED-PTR @0x%08" HWADDR_PRIx
                 " -> 0x%08" PRIx64 "  [dhd read_pcie_ipc]", addr, val);
    } else if (addr >= s->prop_shared_info_off &&
               addr < s->prop_shared_info_off + 0x100) {
        TRACE(s, "*** TCM read SHARED-INFO @0x%08" HWADDR_PRIx
                 " (+0x%03" HWADDR_PRIx ") sz=%u -> 0x%08" PRIx64,
              addr, addr - s->prop_shared_info_off, size, val);
        if (!s->shared_stamped) {
            TRACE(s, "    (note: shared struct not yet stamped)");
        } else if (s->ipc_state == IPC_SHARED_PUBLISHED) {
            s->ipc_state = IPC_TRAINING;
            TRACE(s, "    >>> IPC training commences <<<");
        }
    }
    return val;
}

static void bcm_tcm_write(void *opaque, hwaddr addr, uint64_t val, unsigned size)
{
    BcmFmacStubState *s = opaque;
    uint8_t *tcm = s->tcm_buf;
    if (tcm && addr + size <= TCM_SIZE) {
        memcpy(tcm + addr, &val, size);
    }

    /* During firmware download these are bulk image writes: count, sample. */
    if (s->ipc_state == IPC_RESET || s->ipc_state == IPC_FW_LOADING) {
        if (s->ipc_state == IPC_RESET) {
            s->ipc_state = IPC_FW_LOADING;
            TRACE(s, "firmware download begins (first TCM write @0x%08"
                     HWADDR_PRIx ")", addr);
        }
        s->fw_bytes_written += size;
        if ((s->fw_bytes_written & 0xfffff) == 0) {
            TRACE(s, "firmware download progress: %" PRIu64 " KiB",
                  s->fw_bytes_written >> 10);
        }
    } else {
        /* post-boot writes: host writing ring config / indices into TCM */
        TRACE(s, "TCM write @0x%08" HWADDR_PRIx " sz=%u = 0x%08" PRIx64
                 " (state=%d)", addr, size, val, s->ipc_state);
    }
}

static const MemoryRegionOps bcm_tcm_ops = {
    .read = bcm_tcm_read,
    .write = bcm_tcm_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .impl = { .min_access_size = 1, .max_access_size = 4 },
};

/* ---- config-space write hook: catch the sliding backplane window + reset ---- */
static void bcm_config_write(PCIDevice *pdev, uint32_t addr,
                             uint32_t val, int len)
{
    BcmFmacStubState *s = BCM_FMAC_STUB(pdev);

    if (addr == CFG_BAR0_WINDOW && len == 4) {
        s->bar0_window = val;
        TRACE(s, "CFG BAR0_WINDOW <= backplane 0x%08x", val);
        /* When the host points the window at the ARM core / reset control and
         * later releases it, we treat that as "core released". A precise model
         * would decode the specific core+reset register; for the handshake
         * trace we approximate: once firmware has been loaded and the window is
         * re-pointed away from a download target, publish the shared struct. */
        if (s->ipc_state == IPC_FW_LOADING && s->fw_bytes_written > 0) {
            TRACE(s, "fw downloaded (%" PRIu64 " bytes); core release assumed -> "
                     "publishing candidate IPC shared struct",
                  s->fw_bytes_written);
            s->ipc_state = IPC_CORE_RELEASED;
            bcm_publish_shared(s);
        }
    }

    pci_default_write_config(pdev, addr, val, len);
}

/* ---- config-space read hook (CP-2): log every config read dhd issues during
 * dhdpcie_init so we can see the "device not accessible" gate. dhd typically
 * reads VENDOR/DEVICE id, COMMAND, the PCIe cap (link status), and pokes the
 * sliding BAR0_WINDOW. Logging these reveals which check fails. ---- */
static uint32_t bcm_config_read(PCIDevice *pdev, uint32_t addr, int len)
{
    BcmFmacStubState *s = BCM_FMAC_STUB(pdev);
    uint32_t val = pci_default_read_config(pdev, addr, len);
    (void)s;   /* used only inside the TRACE() expansion below */
    /* Skip the high-frequency uninteresting 1-byte capability walk noise by
     * only tracing word/dword reads and the known-interesting offsets. */
    if (len >= 2 || addr == CFG_BAR0_WINDOW) {
        TRACE(s, "CFG read  off=0x%02x len=%d -> 0x%08x", addr, len, val);
    }
    return val;
}

/* ---- realize ---- */
static void bcm_fmac_realize(PCIDevice *pdev, Error **errp)
{
    BcmFmacStubState *s = BCM_FMAC_STUB(pdev);
    uint8_t *cfg = pdev->config;

    /* class code 0x028000 (network controller / other) */
    pci_set_word(cfg + PCI_CLASS_DEVICE, BCM_CLASS_NETWORK_OTHER);
    cfg[PCI_INTERRUPT_PIN] = 1; /* INTA fallback if MSI off */

    /* Subsystem IDs. dhdpcie_prepare_pcie_ep() reads pdev->subsystem_device
     * (struct pci_dev +62, sourced from cfg 0x2e) and branches on it:
     * the path that recognizes a 6717/6726-class part requires
     *   (subsys_devid - 0x6024) & 0xffff <= 0xd   (i.e. 0x6024..0x6031)
     * GT-BE98 nvram advertises 1:devid=0x602d, which lands in that window.
     * Set sub-vendor 0x14e4, sub-device 0x602d so dhd takes the recognized
     * path (then the cfg 0x6c liveness nibble gate below).  [RE-CONFIRMED:
     * the 0x6024..0x6031 acceptance window from disasm; 0x602d from nvram]. */
    pci_set_word(cfg + PCI_SUBSYSTEM_VENDOR_ID, BCM_VENDOR_ID);
    pci_set_word(cfg + PCI_SUBSYSTEM_ID, 0x602d);

    /* BAR0: backplane register window (MMIO) */
    memory_region_init_io(&s->bar0, OBJECT(s), &bcm_bar0_ops, s,
                          "bcm-fmac.bar0", BAR0_SIZE);
    pci_register_bar(pdev, 0, PCI_BASE_ADDRESS_SPACE_MEMORY, &s->bar0);

    /* BAR2: TCM (dongle RAM window), 64-bit prefetchable like real part.
     * Backed by RAM so firmware download + shared struct persist + are
     * directly hexdumpable for the layout capture. */
    s->tcm_buf = g_malloc0(TCM_SIZE);
    memory_region_init_io(&s->tcm, OBJECT(s), &bcm_tcm_ops, s,
                          "bcm-fmac.tcm", TCM_SIZE);
    pci_register_bar(pdev, 2,
                     PCI_BASE_ADDRESS_SPACE_MEMORY |
                     PCI_BASE_ADDRESS_MEM_TYPE_64 |
                     PCI_BASE_ADDRESS_MEM_PREFETCH,
                     &s->tcm);

    /* PCIe Express capability (CP-2): the real Broadcom dongle is a PCIe
     * endpoint and dhd's dhdpcie_init() reads config 0x6c (inside the PCIe cap
     * region: Link Control 2 / Device Status 2) to confirm the device is
     * "accessible". Without a PCIe cap, 0x6c reads 0 and dhd aborts with
     * "device not accessible" before ever touching BAR0 (captured in
     * traces/cp2-dhd-device-not-accessible.txt). Broadcom places the Express
     * cap at config 0x44; the PCIe v2 cap spans 0x44..0x7f, so 0x6c lands at
     * Express-cap offset 0x28 (PCI_EXP_LNKSTA2 / DevCtl2 region) and reads
     * non-zero once initialized, while leaving CFG_BAR0_WINDOW (0x80, the
     * vendor sliding-backplane dword) untouched. */
    pdev->cap_present |= QEMU_PCI_CAP_EXPRESS;   /* mark as PCIe before cap init */
    if (pcie_endpoint_cap_init(pdev, 0x44) < 0) {
        /* non-fatal for the harness */
    }
    /* dhd's dhdpcie_prepare_pcie_ep() "device accessible" gate (RE-CONFIRMED by
     * disasm of dhd.ko @0x4ddf0):
     *   w23 = pdev->subsystem_device (struct pci_dev +62)
     *   reads cfg 0x00 (vendor==0x14e4), cfg 0x110 -> w21, then for the
     *   subsys-devid-recognized path reads cfg 0x6c (4 bytes) and does
     *       tst w0, #0xf0 ; b.eq <fail -> return -40>
     * i.e. the gate is NOT "0x6c nonzero" (the prior CP-2 guess) but
     * specifically "(cfg6c & 0xF0) != 0".  cfg 0x6c == Express-cap+0x28 here
     * (DevCtl2/DevSta2 region).  The 0xF0-mask is a vendor-defined PCIe-gen /
     * capability nibble dhd polls for liveness.  Set bits[7:4] so the gate
     * passes; keep the value otherwise minimal.  [RE-CONFIRMED: mask 0xF0 gate;
     * exact real-dongle nibble value still DYN]. */
    pci_set_long(cfg + 0x6c, 0x000000f0);
    pci_set_long(pdev->wmask + 0x6c, 0x00000000);
    /* cfg 0x110 VSEC: dhd reads it into w21 and, if nonzero, writes it back
     * (cleared-on-read AER-style scratch behaviour) at the end of
     * prepare_pcie_ep.  QEMU's uninitialized ext-config returns garbage
     * (0x62737973 = ASCII).  Zero it to a defined value so the path is
     * deterministic and the writeback is skipped.  [DYN: real VSEC contents
     * not yet needed to clear this gate]. */
    pci_set_long(cfg + 0x110, 0x00000000);
    pci_set_long(pdev->wmask + 0x110, 0xffffffff);
    /* PCI_EXP_LNKSTA (express+0x12) = link up, Gen2 (0x2), width x1 (0x10). */
    pci_set_word(cfg + 0x44 + 0x12, 0x0012);

    /* MSI: dhd uses MSI. One vector is enough for the handshake. Place the MSI
     * cap at 0xC0 so it collides with neither the PCIe Express cap (0x44..0x7f)
     * nor CFG_BAR0_WINDOW (0x80). */
    if (msi_init(pdev, 0xC0, 1, true, false, errp) < 0) {
        /* non-fatal: fall back to INTx */
    }

    s->bar0_window = CHIPCOMMON_BASE; /* default window at ChipCommon */
    s->ipc_state = IPC_RESET;
    s->fw_bytes_written = 0;
    s->shared_stamped = false;

    TRACE(s, "realized: vendor=0x%04x device=0x%04x class=0x%04x "
             "BAR0=%uB TCM=%uMiB chipid=0x%x ipc_rev=0x%02x",
          BCM_VENDOR_ID, pci_get_word(cfg + PCI_DEVICE_ID),
          BCM_CLASS_NETWORK_OTHER, BAR0_SIZE, (unsigned)(TCM_SIZE / MiB),
          s->prop_chipid, s->prop_ipc_rev);
}

static void bcm_fmac_reset(DeviceState *dev)
{
    BcmFmacStubState *s = BCM_FMAC_STUB(dev);
    s->intstatus = s->intmask = s->mailboxint = 0;
    s->mailboxmask = s->pcie2_intmask = 0;
    s->h2d_mailbox_0 = s->h2d_mailbox_1 = 0;
    s->ipc_state = IPC_RESET;
    s->fw_bytes_written = 0;
    s->shared_stamped = false;
    s->bar0_window = CHIPCOMMON_BASE;
}

static const Property bcm_fmac_props[] = {
    DEFINE_PROP_UINT32("chipid", BcmFmacStubState, prop_chipid, BCM_DEFAULT_DEVICE_ID),
    DEFINE_PROP_UINT32("chiprev", BcmFmacStubState, prop_chiprev, 0),
    DEFINE_PROP_UINT8("ipc-rev", BcmFmacStubState, prop_ipc_rev, DEFAULT_IPC_REV),
    DEFINE_PROP_UINT32("ram-base", BcmFmacStubState, prop_ram_base, DEFAULT_RAM_BASE),
    DEFINE_PROP_UINT32("ram-size", BcmFmacStubState, prop_ram_size, DEFAULT_RAM_SIZE),
    DEFINE_PROP_UINT32("shared-ptr-off", BcmFmacStubState, prop_shared_ptr_off, DEFAULT_SHARED_PTR_OFF),
    DEFINE_PROP_UINT32("shared-info-off", BcmFmacStubState, prop_shared_info_off, DEFAULT_SHARED_INFO_OFF),
};

static const VMStateDescription vmstate_bcm_fmac = {
    .name = TYPE_BCM_FMAC_STUB,
    .version_id = 1,
    .minimum_version_id = 1,
    .fields = (const VMStateField[]) {
        VMSTATE_PCI_DEVICE(parent_obj, BcmFmacStubState),
        VMSTATE_END_OF_LIST()
    },
};

static void bcm_fmac_class_init(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);
    PCIDeviceClass *k = PCI_DEVICE_CLASS(klass);

    k->realize = bcm_fmac_realize;
    k->config_write = bcm_config_write;
    k->config_read = bcm_config_read;
    k->vendor_id = BCM_VENDOR_ID;
    k->device_id = BCM_DEFAULT_DEVICE_ID;
    k->class_id  = 0x0280;   /* network controller, other */
    k->revision  = 0x01;

    dc->desc = "Broadcom BCM6717/6726 FullMAC WiFi dongle (dhd RE stub)";
    dc->vmsd = &vmstate_bcm_fmac;
    device_class_set_legacy_reset(dc, bcm_fmac_reset);
    device_class_set_props(dc, bcm_fmac_props);
    set_bit(DEVICE_CATEGORY_NETWORK, dc->categories);
}

static const TypeInfo bcm_fmac_info = {
    .name = TYPE_BCM_FMAC_STUB,
    .parent = TYPE_PCI_DEVICE,
    .instance_size = sizeof(BcmFmacStubState),
    .class_init = bcm_fmac_class_init,
    .interfaces = (InterfaceInfo[]) {
        /* CP-2: expose as a PCI Express endpoint so pcie_endpoint_cap_init()
         * works and dhd's dhdpcie_init() PCIe-cap accessibility read (0x6c)
         * returns non-zero. */
        { INTERFACE_PCIE_DEVICE },
        { INTERFACE_CONVENTIONAL_PCI_DEVICE },
        { },
    },
};

static void bcm_fmac_register_types(void)
{
    type_register_static(&bcm_fmac_info);
}

type_init(bcm_fmac_register_types)

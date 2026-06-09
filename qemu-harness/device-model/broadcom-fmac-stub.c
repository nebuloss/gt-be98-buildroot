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
/* SiliconBackplane ChipCommon enumeration base on these parts. si_attach()
 * sets the BAR0 window to the ChipCommon core and reads offset 0 = chipid reg.
 * chipid register layout: [15:0]=id [19:16]=rev(packaged separately) ... */
#define CHIPCOMMON_BASE          0x18000000u
#define CHIPCOMMON_CHIPID_OFF    0x00

/* ---- mailbox / doorbell bits (from brcmfmac pcie.c) ---- */
#define D2H_DEV_D3_ACK           0x00000001
#define MB_INT_D2H_DB            0x0000F000   /* D2H doorbell aggregate */
#define H2D_HOST_D0_INFORM       0x00000010

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

    /* ChipCommon chipid register */
    if (bp == (CHIPCOMMON_BASE + CHIPCOMMON_CHIPID_OFF)) {
        /* chipid reg: bits[15:0]=id, bits[19:16]=rev (approx), bits[28:25]=pkg */
        val = (s->prop_chipid & 0xffff) |
              ((s->prop_chiprev & 0xf) << 16);
        TRACE(s, "BAR0 read CHIPID bp=0x%08x -> 0x%08" PRIx64
                 "  (id=0x%x rev=%u)  [si_attach]",
              bp, val, s->prop_chipid & 0xffff, s->prop_chiprev);
        return val;
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

/* ---- realize ---- */
static void bcm_fmac_realize(PCIDevice *pdev, Error **errp)
{
    BcmFmacStubState *s = BCM_FMAC_STUB(pdev);
    uint8_t *cfg = pdev->config;

    /* class code 0x028000 (network controller / other) */
    pci_set_word(cfg + PCI_CLASS_DEVICE, BCM_CLASS_NETWORK_OTHER);
    cfg[PCI_INTERRUPT_PIN] = 1; /* INTA fallback if MSI off */

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

    /* MSI: dhd uses MSI. One vector is enough for the handshake. */
    if (msi_init(pdev, 0, 1, true, false, errp) < 0) {
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
        { INTERFACE_CONVENTIONAL_PCI_DEVICE },
        { },
    },
};

static void bcm_fmac_register_types(void)
{
    type_register_static(&bcm_fmac_info);
}

type_init(bcm_fmac_register_types)

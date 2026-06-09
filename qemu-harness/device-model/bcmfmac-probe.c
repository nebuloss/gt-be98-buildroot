// SPDX-License-Identifier: GPL-2.0
/*
 * bcmfmac-probe: a minimal Linux PCI driver that binds the QEMU
 * broadcom-fmac-stub device (vendor 0x14e4, class 0x028000) and replays the
 * EARLY portion of the closed dhd.ko probe sequence, so the QEMU device-model
 * handshake state machine can be exercised + traced on a STOCK 4.19.294 kernel
 * (one that does not carry ASUS's 12 Broadcom dep modules, so dhd.ko itself
 * cannot be insmod'd here).
 *
 * It mirrors dhd's dhdpcie_probe_attach order, using the same register offsets
 * (from brcmfmac pcie.c):
 *   1. map BAR0 (backplane reg window) + BAR2 (TCM dongle RAM),
 *   2. read the ChipCommon chipid via the BAR0 sliding window  (= si_attach),
 *   3. write rtecdc.bin-shaped bytes into TCM                   (= fw download),
 *   4. poke the config-space BAR0_WINDOW to signal "core release",
 *   5. read the PCIe-IPC shared pointer + shared struct from TCM,
 *   6. ring the H2D doorbell and wait for the MSI/INTx back.
 *
 * Every step is printed; combined with the device-model's own trace this
 * captures the full host<->device handshake transcript.
 *
 * This is a HARNESS EXERCISER, not the real driver. The real RE target is the
 * closed dhd.ko run against the same device-model on the merlin kernel ABI
 * (see qemu-harness/README.md "Next blocker").
 */
#include <linux/module.h>
#include <linux/pci.h>
#include <linux/io.h>
#include <linux/delay.h>
#include <linux/interrupt.h>

#define DRV "bcmfmac-probe"

/* register offsets, identical to brcmfmac pcie.c / dhd */
#define CFG_BAR0_WINDOW     0x80
#define REG_MAILBOXINT      0x48
#define REG_INTSTATUS       0x90
#define REG_INTMASK         0x94
#define REG_SBMBX           0x98
#define REG_H2D_MAILBOX_0   0x140

#define CHIPCOMMON_BASE     0x18000000u
#define SHARED_PTR_OFF      (4u * 1024 * 1024 - 4) /* matches stub default */

struct bcm_probe {
    struct pci_dev *pdev;
    void __iomem *bar0;
    void __iomem *tcm;
    int irq;
};

static irqreturn_t bcm_isr(int irq, void *data)
{
    struct bcm_probe *p = data;
    u32 mbi = ioread32(p->bar0 + REG_MAILBOXINT);
    pr_info(DRV ": ISR fired irq=%d MAILBOXINT=0x%08x INTSTATUS=0x%08x\n",
            irq, mbi, ioread32(p->bar0 + REG_INTSTATUS));
    /* W1C ack */
    iowrite32(mbi, p->bar0 + REG_MAILBOXINT);
    return IRQ_HANDLED;
}

static int bcm_probe(struct pci_dev *pdev, const struct pci_device_id *id)
{
    struct bcm_probe *p;
    u32 chipid, sh_ptr, w;
    int i, ret;

    pr_info(DRV ": PROBE vendor=0x%04x device=0x%04x class=0x%06x\n",
            pdev->vendor, pdev->device, pdev->class);

    p = devm_kzalloc(&pdev->dev, sizeof(*p), GFP_KERNEL);
    if (!p)
        return -ENOMEM;
    p->pdev = pdev;

    ret = pcim_enable_device(pdev);
    if (ret) {
        pr_err(DRV ": enable failed %d\n", ret);
        return ret;
    }
    pci_set_master(pdev);

    p->bar0 = pci_iomap(pdev, 0, 0);
    p->tcm  = pci_iomap(pdev, 2, 0);
    if (!p->bar0 || !p->tcm) {
        pr_err(DRV ": iomap failed bar0=%px tcm=%px\n", p->bar0, p->tcm);
        return -ENOMEM;
    }
    pr_info(DRV ": BAR0=%px (len=%llu) TCM=%px (len=%llu)\n",
            p->bar0, (u64)pci_resource_len(pdev, 0),
            p->tcm,  (u64)pci_resource_len(pdev, 2));

    /* --- step 2: si_attach -> read ChipCommon chipid via BAR0 window --- */
    pci_write_config_dword(pdev, CFG_BAR0_WINDOW, CHIPCOMMON_BASE);
    chipid = ioread32(p->bar0 + 0x00);
    pr_info(DRV ": [si_attach] ChipCommon chipid reg = 0x%08x"
            " (id=0x%04x rev=%u)\n",
            chipid, chipid & 0xffff, (chipid >> 16) & 0xf);

    /* --- step 3: firmware download (write rtecdc-shaped bytes into TCM) --- */
    pr_info(DRV ": [fw download] writing 64 KiB sentinel image into TCM...\n");
    /* LFOC magic so the device-model sees a plausible image head */
    iowrite32(0x434f464c, p->tcm + 0); /* "LFOC" little-endian */
    for (i = 4; i < 64 * 1024; i += 4)
        iowrite32(0xa5a5a5a5, p->tcm + i);

    /* --- step 4: signal core release via the BAR0 window re-point --- */
    pr_info(DRV ": [core release] re-pointing BAR0 window (reset deassert)\n");
    pci_write_config_dword(pdev, CFG_BAR0_WINDOW, CHIPCOMMON_BASE);

    /* give the model a moment to publish the shared struct */
    usleep_range(1000, 2000);

    /* --- step 5: read the PCIe-IPC shared pointer + shared struct --- */
    sh_ptr = ioread32(p->tcm + SHARED_PTR_OFF);
    pr_info(DRV ": [read_pcie_ipc] shared-ptr @TCM[0x%08x] = 0x%08x\n",
            SHARED_PTR_OFF, sh_ptr);
    if (sh_ptr && sh_ptr < pci_resource_len(pdev, 2)) {
        u32 rev = ioread32(p->tcm + sh_ptr);
        pr_info(DRV ": [read_pcie_ipc] shared-info @0x%08x: word0=0x%08x"
                " (ipc_rev=0x%02x)\n", sh_ptr, rev, rev & 0xff);
        for (i = 0; i < 16; i++) {
            w = ioread32(p->tcm + sh_ptr + i * 4);
            pr_info(DRV ":   shared+0x%02x = 0x%08x\n", i * 4, w);
        }
    } else {
        pr_info(DRV ": [read_pcie_ipc] shared-ptr out of range / zero\n");
    }

    /* --- step 6: MSI + doorbell --- */
    ret = pci_alloc_irq_vectors(pdev, 1, 1, PCI_IRQ_MSI | PCI_IRQ_LEGACY);
    if (ret >= 0) {
        p->irq = pci_irq_vector(pdev, 0);
        if (request_irq(p->irq, bcm_isr, IRQF_SHARED, DRV, p) == 0)
            pr_info(DRV ": IRQ %d hooked (%s)\n", p->irq,
                    pdev->msi_enabled ? "MSI" : "INTx");
    }
    pr_info(DRV ": [doorbell] ring H2D_MAILBOX_0\n");
    iowrite32(0x1, p->bar0 + REG_H2D_MAILBOX_0);
    usleep_range(2000, 4000);

    pr_info(DRV ": probe sequence complete (handshake transcript captured)\n");
    pci_set_drvdata(pdev, p);
    return 0;
}

static void bcm_remove(struct pci_dev *pdev)
{
    struct bcm_probe *p = pci_get_drvdata(pdev);
    if (p && p->irq)
        free_irq(p->irq, p);
    pci_free_irq_vectors(pdev);
    pr_info(DRV ": remove\n");
}

/* match by class 0x028000 (network/other), like dhd's alias; also accept the
 * stub's explicit 0x6717 device id. */
static const struct pci_device_id bcm_ids[] = {
    { PCI_DEVICE(0x14e4, 0x6717) },
    { PCI_DEVICE_CLASS(0x028000, 0xffff00),
      .vendor = 0x14e4, .device = PCI_ANY_ID,
      .subvendor = PCI_ANY_ID, .subdevice = PCI_ANY_ID },
    { 0 }
};
MODULE_DEVICE_TABLE(pci, bcm_ids);

static struct pci_driver bcm_driver = {
    .name = DRV,
    .id_table = bcm_ids,
    .probe = bcm_probe,
    .remove = bcm_remove,
};
module_pci_driver(bcm_driver);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("QEMU broadcom-fmac-stub exerciser: replays dhd early probe + IPC handshake");

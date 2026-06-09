// SPDX-License-Identifier: GPL-2.0
/*
 * bcm_pcie_hcd_shim — CP-2 QEMU harness ONLY.
 *
 * The real closed bcm_pcie_hcd.ko hangs in its init_module/probe spinning in a
 * __const_udelay() poll loop waiting for the Broadcom PCIe root-complex link to
 * come up (bcm963xx_hc_is_pcie_link_up / hc_core_reset) — that RC does not exist
 * under qemu-system-aarch64 -M virt (the emulated 14e4 FullMAC device sits on the
 * generic PCI host bridge, not the Broadcom RC), so finit_module never returns and
 * the dep chain never reaches dhd.ko.
 *
 * dhd.ko imports exactly two symbols from bcm_pcie_hcd:
 *   bcm_pcie_map_bar_addr() / bcm_pcie_config_bar_addr()
 * and they are only called on the *Runner offload* TX/RX setup path
 * (dhd_runner.c), which the harness/CP-5 plan explicitly disables
 * ("Force disabling Runner Offload"). They are NOT on dhd's IPC probe path.
 *
 * This shim provides those two symbols as no-op stubs so the real dhd.ko loads
 * and probes the emulated device WITHOUT touching/modifying any closed module.
 * It is loaded *instead of* the real bcm_pcie_hcd.ko in the harness initramfs.
 * RESEARCH-ONLY; never flashed.
 */
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/pci.h>

phys_addr_t bcm_pcie_map_bar_addr(struct pci_dev *pdev, phys_addr_t addr, u32 size)
{
	/* Identity map: on -M virt the BAR phys addr is already CPU-addressable. */
	pr_info("bcm_pcie_hcd_shim: map_bar_addr(addr=%pa size=0x%x) -> identity\n",
		&addr, size);
	return addr;
}
EXPORT_SYMBOL(bcm_pcie_map_bar_addr);

int bcm_pcie_config_bar_addr(struct pci_dev *pdev, int bar, phys_addr_t addr, u32 size)
{
	/* No Broadcom RC inbound window to program under -M virt; report success
	 * so the (disabled) Runner offload path does not error out if ever hit. */
	pr_info("bcm_pcie_hcd_shim: config_bar_addr(bar=%d addr=%pa size=0x%x) -> noop ok\n",
		bar, &addr, size);
	return 0;
}
EXPORT_SYMBOL(bcm_pcie_config_bar_addr);

static int __init bcm_pcie_hcd_shim_init(void)
{
	pr_info("bcm_pcie_hcd_shim: loaded (QEMU -M virt harness; real RC bring-up skipped)\n");
	return 0;
}

static void __exit bcm_pcie_hcd_shim_exit(void) {}

module_init(bcm_pcie_hcd_shim_init);
module_exit(bcm_pcie_hcd_shim_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("CP-2 harness shim: bcm_pcie BAR-helper stubs (no RC bring-up)");

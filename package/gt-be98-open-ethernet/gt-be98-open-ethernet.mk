################################################################################
#
# gt-be98-open-ethernet
#
################################################################################

# branch oe-eth-lan-2026-11-02 = console-stall-2026-10-26 (95657d5: netconsole
# be98pc bootcon handover 0510, panic nbcon flush 0511, Runner netpoll-safe TX
# lock; PCIe 0906) + the RTL8372 read-only monitor (driver/rtl8372, off by
# default), DT patch 0309 (the switch's SMI node at MDIO 29, no reset) and
# 0602-0604 (BCM6813 pinctrl: MDC/MDIO on pins 54/55, so the BCM84891L at 21
# and the switch's SMI answer; rnr3's PHY attach -19 root cause), 0605 (the
# RTL8372 RESET#, GPIO 14 active low, on the switch node: held in reset until
# rtl8372 binds) and 0703 (a flashless BCM8489x no longer has autoneg off);
# rtl8372.ko owns the switch's RESET# (the MDIO core resets PHY devices only)
# console-stall-2026-10-26 2026-11-03 b3ca337 (box-verified: W2 leak watch - per-radio injected-but-unaccounted counter + notice log; on top of 3ce4816)
# console-stall-2026-10-26 2026-11-04 816dc90 (RUNNER-G2: secondary BSS netdevs join the Runner WLAN radio,
#  provider ABI 4 attach_bss/detach_bss - pairs with open-wifi e0f00e1a; flowcache: an IPv4/IPv6 L2 entry always
#  gets the tcp_pure_ack key variant; on top of b3ca337)
# oe-mlo-0907-2026-11-09 2026-11-09 a9960de (= console-stall 1968937 + PCIe 0907: BCM6813 run-time
#  peer-to-peer inbound windows, brcm_pcie_p2p_window_open/_close exported for the open-wifi MLO BRIDGE
#  step; inert unless a driver calls them - no register write at probe or resume; no Kconfig change).
#  The kernel series changed: an existing output tree needs linux-dirclean.
# br-cohbench-2026-11-10 (BENCH ONLY, D31): oe-cohbench-2026-11-10 = a9960de + series.coh-bench (0990 outer
#  shareable, 0991 BCM6813 IO-coherent root complex when dma-coherent). Never on a release branch.
GT_BE98_OPEN_ETHERNET_VERSION = 79887b312e39ca5120884f705aee85c261e32255
GT_BE98_OPEN_ETHERNET_SITE = git@github.com:nebuloss/gt-be98-open-ethernet.git
GT_BE98_OPEN_ETHERNET_SITE_METHOD = git
GT_BE98_OPEN_ETHERNET_LICENSE = GPL-2.0
GT_BE98_OPEN_ETHERNET_INSTALL_IMAGES = YES
GT_BE98_OPEN_ETHERNET_INSTALL_TARGET = YES

GT_BE98_OPEN_ETHERNET_PATCH_DIR = $(GT_BE98_OPEN_ETHERNET_DIR)/kernel-patches/mainline
# kernel-patches/mainline/README, "Apply order"
GT_BE98_OPEN_ETHERNET_SERIES = series.pmb series series.phy series.phylink \
	series.postcode series.usb series.mdio series.mdio-debug series.rxfcs \
	series.mpm series.pcie series.coh-bench

GT_BE98_OPEN_ETHERNET_MODULE_SUBDIRS =
ifeq ($(BR2_PACKAGE_GT_BE98_OPEN_ETHERNET_RUNNER),y)
GT_BE98_OPEN_ETHERNET_MODULE_SUBDIRS += driver/runner
endif
# the RTL8372 LAN switch read-only monitor (off by default)
ifeq ($(BR2_PACKAGE_GT_BE98_OPEN_ETHERNET_RTL8372),y)
GT_BE98_OPEN_ETHERNET_MODULE_SUBDIRS += driver/rtl8372
endif
ifneq ($(strip $(GT_BE98_OPEN_ETHERNET_MODULE_SUBDIRS)),)
$(eval $(kernel-module))
endif

# tools/mainline-boot for post-image.sh: mkbootfs.py (FIT), the board dts
# wrapper and the config fragments / command line gen-linux-config.sh uses.
define GT_BE98_OPEN_ETHERNET_INSTALL_IMAGES_CMDS
	mkdir -p $(HOST_DIR)/share/gt-be98-mainline
	rm -rf $(HOST_DIR)/share/gt-be98-mainline/mainline-boot
	cp -a $(@D)/tools/mainline-boot $(HOST_DIR)/share/gt-be98-mainline/mainline-boot
	echo $(GT_BE98_OPEN_ETHERNET_VERSION) > \
		$(HOST_DIR)/share/gt-be98-mainline/open-ethernet.version
endef

$(eval $(generic-package))

# The kernel patch series. The kernel is patched after this package is
# extracted (an order-only prerequisite: Buildroot's PATCH_DEPENDENCIES cannot
# be set from an external tree, linux.mk is parsed first), then every series
# file is applied in README order with Buildroot's apply-patches.sh.
ifeq ($(BR2_PACKAGE_GT_BE98_OPEN_ETHERNET_KERNEL_PATCHES),y)
$(LINUX_TARGET_PATCH): | gt-be98-open-ethernet-extract

# apply-patches.sh applies a directory's own "series" file and ignores any
# file pattern, and kernel-patches/mainline/series is only one of the
# lists: so build a directory with one combined series (README order) and
# links to the patches, and let apply-patches.sh apply that (patch -F0).
GT_BE98_KSERIES_DIR = $(BUILD_DIR)/gt-be98-kernel-series
define GT_BE98_LINUX_APPLY_SERIES
	@$(call MESSAGE,"Applying the GT-BE98 kernel series ($(GT_BE98_OPEN_ETHERNET_VERSION))")
	$(Q)rm -rf $(GT_BE98_KSERIES_DIR) && mkdir -p $(GT_BE98_KSERIES_DIR)
	$(Q)set -e; for s in $(GT_BE98_OPEN_ETHERNET_SERIES); do \
		f=$(GT_BE98_OPEN_ETHERNET_PATCH_DIR)/$$s; \
		test -f $$f || { echo "missing $$f"; exit 1; }; \
		for p in `grep -Ev '^(#|$$)' $$f | cut -d' ' -f1`; do \
			ln -s $(GT_BE98_OPEN_ETHERNET_PATCH_DIR)/$$p $(GT_BE98_KSERIES_DIR)/$$p; \
			echo $$p >> $(GT_BE98_KSERIES_DIR)/series; \
		done; \
	done
	$(Q)echo "GT-BE98 kernel series: `wc -l < $(GT_BE98_KSERIES_DIR)/series` patches"
	$(APPLY_PATCHES) $(@D) $(GT_BE98_KSERIES_DIR)
endef
LINUX_POST_PATCH_HOOKS += GT_BE98_LINUX_APPLY_SERIES
endif

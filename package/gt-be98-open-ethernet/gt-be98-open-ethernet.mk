################################################################################
#
# gt-be98-open-ethernet
#
################################################################################

# branch kernel-stable-7.2 (v7.2.9 stable image work)
GT_BE98_OPEN_ETHERNET_VERSION = 31dc63ee371f26a2d6742cfff0826f63aa2ffef7
GT_BE98_OPEN_ETHERNET_SITE = git@github.com:nebuloss/gt-be98-open-ethernet.git
GT_BE98_OPEN_ETHERNET_SITE_METHOD = git
GT_BE98_OPEN_ETHERNET_LICENSE = GPL-2.0
GT_BE98_OPEN_ETHERNET_INSTALL_IMAGES = YES
GT_BE98_OPEN_ETHERNET_INSTALL_TARGET = YES

GT_BE98_OPEN_ETHERNET_PATCH_DIR = $(GT_BE98_OPEN_ETHERNET_DIR)/kernel-patches/mainline
# kernel-patches/mainline/README, "Apply order"
GT_BE98_OPEN_ETHERNET_SERIES = series.pmb series series.phy series.phylink \
	series.postcode series.usb series.mdio series.mdio-debug series.rxfcs \
	series.mpm series.pcie

ifeq ($(BR2_PACKAGE_GT_BE98_OPEN_ETHERNET_RUNNER),y)
GT_BE98_OPEN_ETHERNET_MODULE_SUBDIRS = driver/runner
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

define GT_BE98_LINUX_APPLY_SERIES
	@$(call MESSAGE,"Applying the GT-BE98 kernel series ($(GT_BE98_OPEN_ETHERNET_VERSION))")
	$(Q)set -e; for s in $(GT_BE98_OPEN_ETHERNET_SERIES); do \
		f=$(GT_BE98_OPEN_ETHERNET_PATCH_DIR)/$$s; \
		test -f $$f || { echo "missing $$f"; exit 1; }; \
		for p in `grep -v '^#' $$f`; do \
			$(APPLY_PATCHES) $(LINUX_DIR) $(GT_BE98_OPEN_ETHERNET_PATCH_DIR) $$p; \
		done; \
	done
endef
LINUX_POST_PATCH_HOOKS += GT_BE98_LINUX_APPLY_SERIES
endif

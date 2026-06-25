################################################################################
#
# gt-be98-bcm-datapath
#
# Closed Broadcom datapath bring-up: the kernel-module set (/lib/modules/4.19.294
# — the BCM_KF datapath .ko + wl/dhd), the bcm_boot_launcher ELF, and the
# /rom/etc early-init tree (rc3.d -> init.d/*.sh, rdpa_init.sh, ...). Together with
# gt-be98-userspace-base (rc/nvram/libs) this lets a fully-generated rootfs bring
# up the HW datapath + network at boot. Proprietary blob hosted as a
# gt-be98-packages GitHub Release asset.
#
################################################################################

GT_BE98_BCM_DATAPATH_VERSION = 1.0
GT_BE98_BCM_DATAPATH_SITE = https://github.com/nebuloss/gt-be98-packages/releases/download/bcm-datapath-$(GT_BE98_BCM_DATAPATH_VERSION)
GT_BE98_BCM_DATAPATH_SOURCE = gt-be98-bcm-datapath-$(GT_BE98_BCM_DATAPATH_VERSION).tar.gz
GT_BE98_BCM_DATAPATH_LICENSE = PROPRIETARY
GT_BE98_BCM_DATAPATH_REDISTRIBUTE = NO

# The tarball (gt-be98-packages/scripts/package-blob.sh) preserves the blobs'
# firmware-relative paths under .../targets/96813GW/fs/. That subtree holds
# lib/modules/4.19.294, bin/bcm_boot_launcher and rom/etc — copy it onto the
# target root so each lands in place (/lib, /bin, /rom).
define GT_BE98_BCM_DATAPATH_INSTALL_TARGET_CMDS
	cp -a `find $(@D) -type d -path '*/targets/96813GW/fs' | head -1`/. $(TARGET_DIR)/
endef

$(eval $(generic-package))

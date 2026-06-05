################################################################################
#
# gt-be98-bootfs
#
# Prebuilt GT-BE98 bootfs FIT (.itb) from gt-be98-packages. Installed into
# $(BINARIES_DIR) for board/gt-be98/post-image.sh to bundle into the .pkgtb.
#
# Version 0031 = extracted from the VALIDATED artifact (the 0001-0031 pkgtb
# flashed and running on the device, sha256 a7dcd0c1…fa01) via
# gt-be98-packages/scripts/extract-pkgtb.sh — embedded bootfs sha256
# 81f38fe09f602c15cd6d0625cf779f317129c25702ef8b338baeef29d23dec73.
#
################################################################################

GT_BE98_BOOTFS_VERSION = 0031
GT_BE98_BOOTFS_SITE = https://github.com/nebuloss/gt-be98-packages/releases/download/bootfs-$(GT_BE98_BOOTFS_VERSION)
GT_BE98_BOOTFS_SOURCE = gt-be98-bootfs-$(GT_BE98_BOOTFS_VERSION).tar.gz
GT_BE98_BOOTFS_LICENSE = PROPRIETARY
GT_BE98_BOOTFS_REDISTRIBUTE = NO

# Boot artifact, not a rootfs file -> install into BINARIES_DIR (output/images).
GT_BE98_BOOTFS_INSTALL_IMAGES = YES
define GT_BE98_BOOTFS_INSTALL_IMAGES_CMDS
	$(INSTALL) -D -m 0644 \
		`find $(@D) -name 'bcm96813GW_uboot_linux.itb' | head -1` \
		$(BINARIES_DIR)/bcm96813GW_uboot_linux.itb
endef

$(eval $(generic-package))

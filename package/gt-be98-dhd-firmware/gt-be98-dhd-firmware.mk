################################################################################
#
# gt-be98-dhd-firmware
#
# Broadcom dhd wireless firmware (rtecdc.bin) for GT-BE98 radios 6717a0 + 6726b0.
# Proprietary blob hosted as a gt-be98-packages GitHub Release asset.
#
################################################################################

GT_BE98_DHD_FIRMWARE_VERSION = 1.0
GT_BE98_DHD_FIRMWARE_SITE = https://github.com/nebuloss/gt-be98-packages/releases/download/dhd-firmware-$(GT_BE98_DHD_FIRMWARE_VERSION)
GT_BE98_DHD_FIRMWARE_SOURCE = gt-be98-dhd-firmware-$(GT_BE98_DHD_FIRMWARE_VERSION).tar.gz
GT_BE98_DHD_FIRMWARE_LICENSE = PROPRIETARY
GT_BE98_DHD_FIRMWARE_REDISTRIBUTE = NO

# The tarball (produced by gt-be98-packages/scripts/package-blob.sh) preserves the
# blob's full firmware-relative path, so locate the dhd dir wherever it sits and
# install it to /rom/etc/wlan/dhd (the merlin rootfs layout).
define GT_BE98_DHD_FIRMWARE_INSTALL_TARGET_CMDS
	$(INSTALL) -d $(TARGET_DIR)/rom/etc/wlan
	cp -a `find $(@D) -type d -name dhd | head -1` $(TARGET_DIR)/rom/etc/wlan/
endef

$(eval $(generic-package))

################################################################################
#
# gt-be98-userspace-base
#
# Core asuswrt userspace binaries (nvram, rc, wl, dhd, httpd) + their proprietary
# ASUS shared-library closure. Prebuilt glibc-2.32 ARM blobs from gt-be98-packages.
#
################################################################################

GT_BE98_USERSPACE_BASE_VERSION = 1.0
GT_BE98_USERSPACE_BASE_SITE = https://github.com/nebuloss/gt-be98-packages/releases/download/userspace-base-$(GT_BE98_USERSPACE_BASE_VERSION)
GT_BE98_USERSPACE_BASE_SOURCE = gt-be98-userspace-base-$(GT_BE98_USERSPACE_BASE_VERSION).tar.gz
GT_BE98_USERSPACE_BASE_LICENSE = PROPRIETARY
GT_BE98_USERSPACE_BASE_REDISTRIBUTE = NO

# The tarball preserves the blobs' firmware-relative paths under .../fs.install/.
# Copy that subtree onto the target root (bin/ sbin/ usr/ lib/ land in place).
define GT_BE98_USERSPACE_BASE_INSTALL_TARGET_CMDS
	cp -a `find $(@D) -type d -name fs.install | head -1`/. $(TARGET_DIR)/
endef

$(eval $(generic-package))

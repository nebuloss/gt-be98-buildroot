################################################################################
#
# gt-be98-nvram
#
# Open libnvram.so + nvram CLI: a clean-room userspace client for the
# NETLINK_WLCSM (proto 31) protocol of the OPEN in-kernel store bcm_knvram.ko.
# Replaces the closed prebuilt vendor libnvram.so / nvram (RE map verdict for
# the netlink client = REIMPLEMENT; the protocol itself is fully open).
#
# Source = this package's src/ (no download); built straight from the protocol
# definitions reproduced from the GPL kernel headers (wlcsm_linux.h) and
# verified against wlcsm_netlink.c / wlcsm_nvram.c. No merlin build-glue, no
# SDK headers, no closed objects - links only libc + libpthread.
#
# NOT wired into gt-be98_full_defconfig (production baseline unchanged). Built
# in isolation for the from-source rootfs track; needs on-device bench
# validation against a live bcm_knvram.ko before use.
#
################################################################################

GT_BE98_NVRAM_VERSION = 1.0
GT_BE98_NVRAM_SITE = $(GT_BE98_NVRAM_PKGDIR)/src
GT_BE98_NVRAM_SITE_METHOD = local
GT_BE98_NVRAM_LICENSE = GPL-2.0
GT_BE98_NVRAM_INSTALL_STAGING = YES

define GT_BE98_NVRAM_BUILD_CMDS
	$(TARGET_CC) $(TARGET_CFLAGS) -Wall -Wextra -fPIC -shared -pthread \
		-I$(@D) $(@D)/libnvram.c -o $(@D)/libnvram.so
	$(TARGET_CC) $(TARGET_CFLAGS) -Wall -Wextra -I$(@D) \
		$(@D)/nvram_cli.c -L$(@D) -lnvram -pthread \
		-Wl,-rpath-link,$(@D) -o $(@D)/nvram
endef

# Staging: let other from-source packages (libshared, rc, hostapd) link -lnvram.
define GT_BE98_NVRAM_INSTALL_STAGING_CMDS
	$(INSTALL) -D -m 0755 $(@D)/libnvram.so $(STAGING_DIR)/usr/lib/libnvram.so
	$(INSTALL) -D -m 0644 $(@D)/nvram.h $(STAGING_DIR)/usr/include/nvram.h
endef

define GT_BE98_NVRAM_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/libnvram.so $(TARGET_DIR)/usr/lib/libnvram.so
	$(INSTALL) -D -m 0755 $(@D)/nvram $(TARGET_DIR)/bin/nvram
endef

$(eval $(generic-package))

################################################################################
#
# gt-be98-open-wifi
#
################################################################################

# main 2026-10-30 29896812 (box-verified: station mode WPA2 + reconnect + AP+STA traffic - the link-up WDSLIST(124)
#  leftover that freed the station's SCB is gone; on top of 4d6520e9's LED/monitor/Runner rebind)
GT_BE98_OPEN_WIFI_VERSION = 298968123458a4e06698c70f1304800af85d09f9
GT_BE98_OPEN_WIFI_SITE = git@github.com:nebuloss/gt-be98-open-wifi.git
GT_BE98_OPEN_WIFI_SITE_METHOD = git
GT_BE98_OPEN_WIFI_LICENSE = GPL-2.0-only
GT_BE98_OPEN_WIFI_MODULE_SUBDIRS = driver

ifeq ($(BR2_PACKAGE_GT_BE98_OPEN_WIFI_BENCH),y)
GT_BE98_OPEN_WIFI_MODULE_MAKE_OPTS = BCA_BENCH_CFLAGS=-DBCA_BENCH_PARAMS
endif

# bca_barpeek.ko (bench builds only) is a reverse-engineering tool: never ship
# (removed after the kernel-module install, in a target-finalize hook)
define GT_BE98_OPEN_WIFI_REMOVE_BARPEEK
	find $(TARGET_DIR)/lib/modules -name bca_barpeek.ko -delete
endef
GT_BE98_OPEN_WIFI_TARGET_FINALIZE_HOOKS += GT_BE98_OPEN_WIFI_REMOVE_BARPEEK

$(eval $(kernel-module))
$(eval $(generic-package))

################################################################################
#
# gt-be98-open-wifi
#
################################################################################

# branch main
GT_BE98_OPEN_WIFI_VERSION = 273270e1dc57b3496d2164bd4ae2f94bdc28a003
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

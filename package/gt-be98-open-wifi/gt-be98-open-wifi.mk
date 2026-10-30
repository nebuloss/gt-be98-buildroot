################################################################################
#
# gt-be98-open-wifi
#
################################################################################

# main 2026-10-30 09fbee8b (box-verified: airtime fairness follows hostapd (fw ATM percentages), bridged Wi-Fi->trunk frames offered to an ABI-3 Runner; on top of 9079dde9)
#  radio + later station no longer steals a client ring), Multi-AP backhaul map/dwds re-applied per connect)
GT_BE98_OPEN_WIFI_VERSION = 09fbee8bc7030595891083a9475f2336567c6a9f
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

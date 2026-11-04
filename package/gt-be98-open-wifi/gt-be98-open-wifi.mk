################################################################################
#
# gt-be98-open-wifi
#
################################################################################

# main 2026-11-03 49d3137a (box-verified: CB-NOTAIL beacon tail kept on a tail-less change_beacon, per-peer power-save answer counters, ledger triage; on top of 1341a24f)
# main 2026-11-02 1341a24f (box-verified: HE/EHT follow hostapd - he/eht features+enab sent to the firmware in the radio-down window; 6 GHz keeps HE)
# main 2026-10-30 71e8f7ce (box-verified 300 cycles: RMDOWN fix A - a remove-time control timeout makes no device access, an unanswered radio-down takes the dead-firmware unwind; on top of 09fbee8b)
# main 2026-10-30 09fbee8b (box-verified: airtime fairness follows hostapd (fw ATM percentages), bridged Wi-Fi->trunk frames offered to an ABI-3 Runner; on top of 9079dde9)
#  radio + later station no longer steals a client ring), Multi-AP backhaul map/dwds re-applied per connect)
# main 2026-11-03 18e96ed2 (box-verified: TX doorbells from a dirty-ring list instead of a full scan per run - 6 GHz Runner-offload CPU ratio 0.52; on top of 49d3137a)
# main 2026-11-04 e0f00e1a (box-verified: BSS0-MAC - the radio's first BSS takes hostapd's bssid= (custom
#  first-network MAC, the 6 GHz LA anchor block: 8 networks on 6 GHz, B0/B0s/B2 PASS); RUNNER-G2 client: secondary
#  BSS netdevs bind to their radio's Runner WLAN slot (provider ABI 4, needs open-ethernet 816dc90); on top of 18e96ed2)
GT_BE98_OPEN_WIFI_VERSION = e0f00e1a27607c4fe6aa14a264347b8937d74ac1
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

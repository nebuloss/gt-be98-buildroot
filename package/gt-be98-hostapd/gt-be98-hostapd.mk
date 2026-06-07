################################################################################
#
# gt-be98-hostapd  (hostapd_cli, vendor-source)
#
# Builds hostapd_cli from the VENDOR GPL hostapd source shipped in the firmware
# tree: upstream hostapd v2.10 + Broadcom patches (impl103). hostapd_cli is the
# self-contained wpa_ctrl client - its only objects are src/common + src/utils
# (hostapd_cli, wpa_ctrl, os_unix, cli, eloop, common, wpa_debug, edit_simple),
# with NO driver backend, NO openssl, NO libnl, NO Broadcom glue. It therefore
# compiles + links clean against the Buildroot cross toolchain (gcc-10.3),
# proving the vendor hostapd source builds from source for this target.
#
# The upstream Makefile unconditionally injects -L$(TOP)/libhostapi -lhostapi
# (LDFLAGS, line ~32) and a default LIBS pulling -lcrypto/-lssl/-lnvram/
# -lshared/-lhostapi; with an empty TOP these become unsafe "/..." paths the
# Buildroot wrapper rejects, and hostapd_cli needs none of them. We override
# LDFLAGS="" and LIBS_c="-lrt" (command-line assignment suppresses the in-file
# += appends).
#
# ---- FULL hostapd DAEMON: NOT BUILT (documented blocker) --------------------
# The device hostapd is the DRIVER_BRCM build (brcm.config: NL80211 + DRIVER_BRCM
# + MLO/MAP/RDKB). That config is gated behind the Broadcom SDK header graph
# ($(HND_SRC)/$(SRCBASE) for ce_shared.h, bcmevent.h, bcmwifi_channels.h,
# typedefs.h, security_ipc.h) and links libceshared (cevent_app), libnl-3 /
# libnl-genl-3, openssl-1.1 (device ABI; Buildroot ships openssl-3), plus
# libnvram + libshared. Reproducing the shipped binary
# (sha256 7453000858a87738146fa0898d75036195a09e965e9b6f8a12e39ec0c7aede2d)
# requires wrapping the merlin SDK build env - the multi-hour glue job deferred
# alongside the kernel build. hostapd_cli here is the available clean win.
#
# Requires the firmware tree (override with GT_BE98_HOSTAPD_MERLIN_ROOT).
# Not wired into gt-be98_full_defconfig.
#
################################################################################

GT_BE98_HOSTAPD_VERSION = 2.10-brcm-impl103
GT_BE98_HOSTAPD_LICENSE = BSD-3-Clause
GT_BE98_HOSTAPD_LICENSE_FILES = COPYING

GT_BE98_HOSTAPD_MERLIN_ROOT ?= $(BR2_EXTERNAL_GT_BE98_PATH)/../gt-be98-firmware/vendor/asuswrt-merlin.ng/release/src-rt-5.04behnd.4916
GT_BE98_HOSTAPD_SITE = $(GT_BE98_HOSTAPD_MERLIN_ROOT)/bcmdrivers/broadcom/net/wl/impl103/main/components/opensource/router_tools/hostapd
GT_BE98_HOSTAPD_SITE_METHOD = local

# Minimal config: hostapd_cli only needs the unix ctrl_iface client.
define GT_BE98_HOSTAPD_CONFIGURE_CMDS
	printf 'CONFIG_CTRL_IFACE=y\nCONFIG_CTRL_IFACE_UNIX=y\n' > $(@D)/hostapd/.config
endef

# NB: pass toolchain flags via EXTRA_CFLAGS (the Makefile does CFLAGS +=
# $(EXTRA_CFLAGS)); a command-line CFLAGS= would suppress the Makefile's own
# CFLAGS += -I../src / -I../src/utils appends and break the build.
define GT_BE98_HOSTAPD_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D)/hostapd hostapd_cli \
		CC="$(TARGET_CC)" EXTRA_CFLAGS="$(TARGET_CFLAGS)" \
		LDFLAGS="" LIBS_c="-lrt"
endef

define GT_BE98_HOSTAPD_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/hostapd/hostapd_cli $(TARGET_DIR)/usr/sbin/hostapd_cli
endef

$(eval $(generic-package))

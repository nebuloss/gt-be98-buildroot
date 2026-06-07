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
# ---- FULL hostapd DAEMON: BUILT FROM SOURCE (BR2_PACKAGE_GT_BE98_HOSTAPD_DAEMON)
# The device hostapd is the DRIVER_BRCM build (brcm.config: NL80211 + DRIVER_BRCM
# + MLO/MAP/SAE/OWE/HS20/WPS + RDKB). It is now built from source via the merlin
# SDK build-glue (src/build-hostapd-daemon.sh -> the vendor router target
# `make -C router hostapd`), which sets up the SDK header graph ($(HND_SRC)/
# $(SRCBASE) for ce_shared.h, bcmevent.h, bcmwifi_channels.h, typedefs.h) and
# the cross PKG_CONFIG_PATH/LD. It links our from-source libshared + libnvram,
# the SDK from-source openssl-1.1 + libnl, and the pinned closed libceshared.so.
#
# RESULT: the from-source daemon, stripped, is BYTE-IDENTICAL to the shipped
# device hostapd (sha256 7453000858a87738146fa0898d75036195a09e965e9b6f8a12e39ec0c7aede2d;
# DT_NEEDED identical) -- a reproducible-build match.
#
# OPENSSL DECISION: the device ABI is openssl-1.1 (libcrypto/libssl.so.1.1) but
# Buildroot ships openssl-3. Rather than carry a from-source openssl-1.1 BR
# package, we graft the SDK's OWN from-source openssl-1.1 build (router/openssl/
# *.so.1.1) into the rootfs. It IS from source (built by the router target), just
# delivered as a graft because the BR openssl is a different major. Same for the
# SDK from-source libnl-3/genl. libceshared.so stays a pinned closed graft.
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

ifeq ($(BR2_PACKAGE_GT_BE98_HOSTAPD_DAEMON),y)
GT_BE98_HOSTAPD_DEPENDENCIES += gt-be98-libshared gt-be98-nvram
GT_BE98_HOSTAPD_FW_ROOT = $(GT_BE98_HOSTAPD_MERLIN_ROOT)
# The daemon's brcm.config build is run by the SDK glue script (its own .config);
# only the hostapd_cli still needs the minimal stub config.
endif

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
	$(if $(BR2_PACKAGE_GT_BE98_HOSTAPD_DAEMON), \
		GTBE98_ROOT="$(GT_BE98_HOSTAPD_FW_ROOT)" \
		SDK="$(GT_BE98_HOSTAPD_MERLIN_ROOT)" \
		PKG_SRC="$(BR2_EXTERNAL_GT_BE98_PATH)/package/gt-be98-libshared/src" \
		OUTDIR="$(@D)" \
			$(SHELL) $(GT_BE98_HOSTAPD_PKGDIR)/src/build-hostapd-daemon.sh)
endef

define GT_BE98_HOSTAPD_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/hostapd/hostapd_cli $(TARGET_DIR)/usr/sbin/hostapd_cli
	$(if $(BR2_PACKAGE_GT_BE98_HOSTAPD_DAEMON),\
		$(INSTALL) -D -m 0755 $(@D)/hostapd.daemon $(TARGET_DIR)/usr/sbin/hostapd ; \
		$(INSTALL) -D -m 0755 $(@D)/libceshared.so $(TARGET_DIR)/usr/lib/libceshared.so ; \
		$(INSTALL) -D -m 0755 $(@D)/libcrypto.so.1.1 $(TARGET_DIR)/usr/lib/libcrypto.so.1.1 ; \
		$(INSTALL) -D -m 0755 $(@D)/libssl.so.1.1 $(TARGET_DIR)/usr/lib/libssl.so.1.1 ; \
		$(INSTALL) -D -m 0755 $(@D)/libnl-3.so.200.20.0 $(TARGET_DIR)/lib/libnl-3.so.200.20.0 ; \
		ln -sf libnl-3.so.200.20.0 $(TARGET_DIR)/lib/libnl-3.so.200 ; \
		$(INSTALL) -D -m 0755 $(@D)/libnl-genl-3.so.200.20.0 $(TARGET_DIR)/lib/libnl-genl-3.so.200.20.0 ; \
		ln -sf libnl-genl-3.so.200.20.0 $(TARGET_DIR)/lib/libnl-genl-3.so.200)
endef

$(eval $(generic-package))

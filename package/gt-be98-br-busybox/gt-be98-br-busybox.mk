################################################################################
#
# gt-be98-br-busybox
#
# Static busybox 1.37.0 for the /usr/br island (M5 candidate 2, br-0042),
# rebuilt FROM SOURCE (br-0044) instead of shipping a prebuilt blob in the
# overlay. Config = upstream defconfig + CONFIG_STATIC + INSTALL_NO_USR +
# SHA1/SHA256_HWACCEL off (x86-only code misgated on ARM in 1.37.0) +
# CONFIG_TC off (parity with the committed br-0042 binary). The applet set
# is pinned by board/gt-be98/br-busybox.links — the harvest step in
# rootfs-transform.sh fails on ANY applet drift.
#
# Nothing is installed to Buildroot's (throwaway) target: rootfs-transform.sh
# harvests $(@D)/_install into the ASUS rootfs at /usr/br/{bin,sbin}.
#
################################################################################

GT_BE98_BR_BUSYBOX_VERSION = 1.37.0
GT_BE98_BR_BUSYBOX_SOURCE = busybox-$(GT_BE98_BR_BUSYBOX_VERSION).tar.bz2
GT_BE98_BR_BUSYBOX_SITE = https://www.busybox.net/downloads
GT_BE98_BR_BUSYBOX_LICENSE = GPL-2.0
GT_BE98_BR_BUSYBOX_LICENSE_FILES = LICENSE

GT_BE98_BR_BUSYBOX_MAKE_OPTS = \
	CROSS_COMPILE="$(TARGET_CROSS)" \
	ARCH=$(NORMALIZED_ARCH)

define GT_BE98_BR_BUSYBOX_CONFIGURE_CMDS
	cp $(GT_BE98_BR_BUSYBOX_PKGDIR)/busybox.config $(@D)/.config
	yes '' | $(MAKE) $(GT_BE98_BR_BUSYBOX_MAKE_OPTS) -C $(@D) oldconfig
endef

# `make` self-strips the binary (same as the manual br-0042 build); install
# regenerates the applet symlinks (bin/<x> -> busybox, sbin/<x> ->
# ../bin/busybox, INSTALL_NO_USR). The stray /linuxrc link is dropped, the
# linuxrc APPLET stays in the binary - exact parity with the committed one.
define GT_BE98_BR_BUSYBOX_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) $(GT_BE98_BR_BUSYBOX_MAKE_OPTS) -C $(@D)
	rm -rf $(@D)/_install
	$(TARGET_MAKE_ENV) $(MAKE) $(GT_BE98_BR_BUSYBOX_MAKE_OPTS) \
		CONFIG_PREFIX=$(@D)/_install -C $(@D) install
	rm -f $(@D)/_install/linuxrc
endef

# no target-install: harvested by board/gt-be98/rootfs-transform.sh

$(eval $(generic-package))

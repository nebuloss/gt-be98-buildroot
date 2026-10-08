################################################################################
#
# gt-be98-rescue-busybox
#
################################################################################

# Same release and tarball as Buildroot's busybox package (shared download).
GT_BE98_RESCUE_BUSYBOX_VERSION = 1.38.0
GT_BE98_RESCUE_BUSYBOX_SITE = https://www.busybox.net/downloads
GT_BE98_RESCUE_BUSYBOX_SOURCE = busybox-$(GT_BE98_RESCUE_BUSYBOX_VERSION).tar.bz2
GT_BE98_RESCUE_BUSYBOX_DL_SUBDIR = busybox
GT_BE98_RESCUE_BUSYBOX_LICENSE = GPL-2.0, bzip2-1.0.4
GT_BE98_RESCUE_BUSYBOX_LICENSE_FILES = LICENSE archival/libarchive/bz/LICENSE
GT_BE98_RESCUE_BUSYBOX_INSTALL_IMAGES = YES

GT_BE98_RESCUE_BUSYBOX_MAKE_OPTS = \
	CC="$(TARGET_CC)" \
	CROSS_COMPILE="$(TARGET_CROSS)" \
	ARCH=arm64 \
	CONFIG_PREFIX="$(@D)/_install" \
	SKIP_STRIP=n

# upstream defconfig, static; tc off (it still uses the CBQ uapi that
# Linux 6.8+ headers dropped); the stage-2 recipe made the same choices
# (open-ethernet tools/mainline-boot/busybox-build.sh).
define GT_BE98_RESCUE_BUSYBOX_CONFIGURE_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D) $(GT_BE98_RESCUE_BUSYBOX_MAKE_OPTS) defconfig
	$(SED) 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' \
		-e 's/^CONFIG_TC=y/# CONFIG_TC is not set/' \
		-e 's/^CONFIG_FEATURE_TC_INGRESS=y/# CONFIG_FEATURE_TC_INGRESS is not set/' \
		-e 's/^CONFIG_EXTRA_CFLAGS=.*/CONFIG_EXTRA_CFLAGS=""/' \
		$(@D)/.config
	yes "" | $(TARGET_MAKE_ENV) $(MAKE) -C $(@D) $(GT_BE98_RESCUE_BUSYBOX_MAKE_OPTS) oldconfig >/dev/null
	grep -qx 'CONFIG_STATIC=y' $(@D)/.config
endef

define GT_BE98_RESCUE_BUSYBOX_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D) $(GT_BE98_RESCUE_BUSYBOX_MAKE_OPTS) busybox
	$(TARGET_STRIP) $(@D)/busybox
	# applets the rescue /init and the lifeline use
	set -e; for c in ASH MOUNT MKDIR SLEEP CUT CAT IP UDHCPC TELNETD DEVMEM \
		LOSETUP SWITCH_ROOT LS SED GREP DMESG INSMOD REBOOT WGET TAR \
		UBIATTACH UBIDETACH HEAD FEATURE_FANCY_HEAD SHA256SUM FINDFS; do \
		grep -qx "CONFIG_$$c=y" $(@D)/.config || \
			{ echo "rescue busybox: CONFIG_$$c missing"; exit 1; }; \
	done
endef

define GT_BE98_RESCUE_BUSYBOX_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/busybox $(TARGET_DIR)/usr/libexec/gt-be98/busybox
endef

define GT_BE98_RESCUE_BUSYBOX_INSTALL_IMAGES_CMDS
	$(INSTALL) -D -m 0755 $(@D)/busybox $(BINARIES_DIR)/rescue/busybox
endef

$(eval $(generic-package))

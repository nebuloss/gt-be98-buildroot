################################################################################
#
# gt-be98-os
#
################################################################################

GT_BE98_OS_VERSION = 1.0
GT_BE98_OS_SITE = $(BR2_EXTERNAL_GT_BE98_PATH)/package/gt-be98-os/src
GT_BE98_OS_SITE_METHOD = local
GT_BE98_OS_LICENSE = GPL-2.0
GT_BE98_OS_INSTALL_IMAGES = YES
GT_BE98_OS_DEPENDENCIES = host-lzop host-dtc host-uboot-tools
GT_BE98_OS_LOCAL_CONF = $(call qstrip,$(BR2_PACKAGE_GT_BE98_OS_LOCAL_CONF))

GT_BE98_OS_SERVICES = gt-be98-watchdog gt-be98-netguard gt-be98-jffs gt-be98-drivers gt-be98-wifi \
	gt-be98-telnet gt-be98-boot-done gt-be98-persist sshd dhcpcd chronyd \
	syslogd dnsmasq

define GT_BE98_OS_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D) CC="$(TARGET_CC)" \
		CFLAGS="$(TARGET_CFLAGS)" LDFLAGS="$(TARGET_LDFLAGS)" devmem nandtool
endef

define GT_BE98_OS_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/devmem $(TARGET_DIR)/usr/sbin/devmem
	$(INSTALL) -D -m 0755 $(@D)/nandtool $(TARGET_DIR)/usr/sbin/gt-be98-nandtool
	for f in gt-be98-postcode gt-be98-health gt-be98-wdtd gt-be98-status \
		gt-be98-macaddr gt-be98-netguard gt-be98-save gt-be98-nandcheck \
		gt-be98-nandpage; do \
		$(INSTALL) -D -m 0755 $(@D)/sbin/$$f $(TARGET_DIR)/usr/sbin/$$f || exit 1; \
	done
	for s in $(GT_BE98_OS_SERVICES); do \
		$(INSTALL) -D -m 0755 $(@D)/init.d/$$s $(TARGET_DIR)/etc/init.d/$$s || exit 1; \
	done
	for c in $(@D)/conf.d/*; do \
		$(INSTALL) -D -m 0644 $$c $(TARGET_DIR)/etc/conf.d/`basename $$c` || exit 1; \
	done
	$(INSTALL) -D -m 0644 $(@D)/dhcpcd-hooks/05-gt-be98-mac \
		$(TARGET_DIR)/lib/dhcpcd/dhcpcd-hooks/05-gt-be98-mac
	mkdir -p $(TARGET_DIR)/rom $(TARGET_DIR)/overlay $(TARGET_DIR)/data \
		$(TARGET_DIR)/etc/ssh/authorized_keys $(TARGET_DIR)/etc/syslog.d
endef

define GT_BE98_OS_INSTALL_IMAGES_CMDS
	$(INSTALL) -D -m 0755 $(@D)/rescue/init $(BINARIES_DIR)/rescue/init
	$(INSTALL) -D -m 0755 $(@D)/rescue/udhcpc.script $(BINARIES_DIR)/rescue/udhcpc.script
endef

# Runs after every package is installed: replace the SysV S* scripts the
# packages install with the OpenRC services above, set the runlevels, and
# apply the lab-specific values of the local configuration file.
define GT_BE98_OS_FINALIZE
	# our /etc files win over the package defaults (sshd_config, dhcpcd.conf,
	# chrony.conf, syslog.conf, dnsmasq.conf, fstab, ...)
	cd $(GT_BE98_OS_DIR)/etc && find . -type f | while read f; do \
		$(INSTALL) -D -m 0644 $$f $(TARGET_DIR)/etc/$$f || exit 1; \
	done
	# the bench-only Wi-Fi RE module is never shipped
	find $(TARGET_DIR)/lib/modules -name bca_barpeek.ko -delete
	# no NAND writing tools in the image, whatever pulled them in
	rm -f $(addprefix $(TARGET_DIR)/usr/sbin/,flash_erase flash_eraseall nandwrite \
		nandtest ubiformat ubimkvol ubirmvol ubirsvol ubiupdatevol ubirename \
		flashcp flash_lock flash_unlock mtd_debug ubiblock)
	# no RTC on the board: hwclock would only fail at every boot
	rm -f $(TARGET_DIR)/etc/runlevels/boot/hwclock
	# no block filesystems to check (the root is squashfs + overlay): fsck
	# -A would fail on the overlay entry and abort the boot runlevel
	rm -f $(TARGET_DIR)/etc/runlevels/boot/fsck
	# no console getty (no UART, no root password)
	rm -f $(TARGET_DIR)/etc/runlevels/default/agetty.*
	rm -f $(TARGET_DIR)/etc/init.d/S[0-9][0-9]* $(TARGET_DIR)/etc/init.d/rcS \
		$(TARGET_DIR)/etc/init.d/rcK
	rm -f $(TARGET_DIR)/etc/runlevels/*/sysv-rcs
	# /var/log: a real directory (the skeleton links it to /tmp)
	if [ -L $(TARGET_DIR)/var/log ]; then rm -f $(TARGET_DIR)/var/log; fi
	mkdir -p $(TARGET_DIR)/var/log
	mkdir -p $(TARGET_DIR)/etc/runlevels/boot $(TARGET_DIR)/etc/runlevels/default
	for s in gt-be98-watchdog gt-be98-netguard gt-be98-persist gt-be98-jffs syslogd; do \
		ln -sfn /etc/init.d/$$s $(TARGET_DIR)/etc/runlevels/boot/$$s; done
	for s in dhcpcd sshd chronyd gt-be98-drivers gt-be98-boot-done; do \
		ln -sfn /etc/init.d/$$s $(TARGET_DIR)/etc/runlevels/default/$$s; done
	GT_BE98_LOCAL_CONF="$(GT_BE98_OS_LOCAL_CONF)" TARGET_DIR="$(TARGET_DIR)" \
		HOST_DIR="$(HOST_DIR)" \
		$(BR2_EXTERNAL_GT_BE98_PATH)/package/gt-be98-os/apply-local-conf.sh
	{ echo "GT-BE98 mainline OS $(GT_BE98_OS_VERSION) (Buildroot $(BR2_VERSION_FULL), Linux $(LINUX_VERSION))"; \
	  echo "open-ethernet $(GT_BE98_OPEN_ETHERNET_VERSION)"; \
	  echo "open-wifi $(GT_BE98_OPEN_WIFI_VERSION)"; \
	  echo "built $$(date -u +%Y-%m-%dT%H:%MZ)"; } > $(TARGET_DIR)/etc/gt-be98-release
endef
GT_BE98_OS_TARGET_FINALIZE_HOOKS += GT_BE98_OS_FINALIZE

$(eval $(generic-package))

# The kernel's CONFIG_INITRAMFS_SOURCE is ${BR_BINARIES_DIR}/gt-be98-initramfs.list
# (board/gt-be98-mainline/linux/linux.config). The first kernel build gets a
# placeholder; post-image.sh writes the real list (rescue BusyBox, /init,
# rootfs.squashfs) and relinks with the exact command saved here.
ifeq ($(BR2_PACKAGE_GT_BE98_OS),y)
define GT_BE98_OS_LINUX_PREPARE_INITRAMFS
	mkdir -p $(BINARIES_DIR)
	test -f $(BINARIES_DIR)/gt-be98-initramfs.list || \
		printf 'dir /dev 0755 0 0\nnod /dev/console 0600 0 0 c 5 1\n' \
			> $(BINARIES_DIR)/gt-be98-initramfs.list
	$(file >$(BUILD_DIR)/gt-be98-linux-relink.sh,$(LINUX_MAKE_ENV) $(BR2_MAKE) -j$(PARALLEL_JOBS) $(LINUX_MAKE_FLAGS) -C $(LINUX_DIR) $(LINUX_TARGET_NAME))
	printf 'LINUX_DIR=%s\nLINUX_VERSION=%s\n' $(LINUX_DIR) $(LINUX_VERSION) \
		> $(BUILD_DIR)/gt-be98-linux.env
endef
LINUX_PRE_BUILD_HOOKS += GT_BE98_OS_LINUX_PREPARE_INITRAMFS
endif

# perf: the build host has a host rustc, so perf's feature check enables the
# Rust test workload and tries to cross-build it without a target std.
ifeq ($(BR2_PACKAGE_GT_BE98_OS)$(BR2_PACKAGE_LINUX_TOOLS_PERF),yy)
PERF_MAKE_FLAGS += NO_RUST=1
endif

################################################################################
#
# gt-be98-vendor-firmware
#
################################################################################

# Nothing to download: the files come from local directories named in the
# local configuration file (not in git). Origins and versions:
# open-ethernet docs/userspace-versions.md, "Vendor firmware".
GT_BE98_VENDOR_FIRMWARE_SOURCE =
GT_BE98_VENDOR_FIRMWARE_LICENSE = PROPRIETARY
GT_BE98_VENDOR_FIRMWARE_REDISTRIBUTE = NO

# <group>:<source path relative to the group dir>:<path under /lib/firmware>:<sha256>
GT_BE98_VENDOR_FIRMWARE_FILES = \
	RUNNER:bcm4916-runner-microcode.bin:brcm/bcm4916-runner-microcode.bin:b48ce349122a428e87fc54d57ad4aad399b5da89186f54fb0b6afea361daebe0 \
	RUNNER:merlin16-shortfin.bin:brcm/merlin16-shortfin.bin:d79d3db80b0c7c1d8b6a2c100d8a76a26565faedbbae03a81be93484660868cd \
	PHY:xphy_firmware.bin:brcm/bcm4916-xphy.bin:204238e182dc054380a7b00a4b5e1bcf6c7895cae45915cee7b2f89e4f477496 \
	PHY:blackfin_b0_firmware.bin:brcm/bcm84891l-b0.bin:c63351f36034ceeeb77ad25679039b25df4d2c476667c7ed8e381194a7996fce \
	WIFI:dhd/6726b0/release/rtecdc.bin:brcm/bca/6726b0/rtecdc.bin:ad6f9433ed9c900f2545af9ffc8c4fb2ae12d00e28629e9117139cc9efc8a687 \
	WIFI:dhd/6717a0/release/rtecdc.bin:brcm/bca/6717a0/rtecdc.bin:886ef632b567ab48028fad31a85302cf5344719811bdc6b124219caf0d21c8d5 \
	WIFI:nvram/GT-BE98.nvm:brcm/bca/GT-BE98.nvm:8c08afb7175103f2bf2b4abee2877122fdb80446e83f4397b4828f540261b66d

GT_BE98_VENDOR_FIRMWARE_LOCAL_CONF = $(call qstrip,$(BR2_PACKAGE_GT_BE98_OS_LOCAL_CONF))

define GT_BE98_VENDOR_FIRMWARE_INSTALL_TARGET_CMDS
	set -e; \
	FW_RUNNER_DIR=; FW_PHY_DIR=; FW_WIFI_DIR=; \
	if [ -n "$(GT_BE98_VENDOR_FIRMWARE_LOCAL_CONF)" ]; then \
		. $(GT_BE98_VENDOR_FIRMWARE_LOCAL_CONF); fi; \
	for e in $(GT_BE98_VENDOR_FIRMWARE_FILES); do \
		g=$${e%%:*}; r=$${e#*:}; src=$${r%%:*}; r=$${r#*:}; \
		dst=$${r%%:*}; sum=$${r#*:}; \
		eval d=\$${FW_$${g}_DIR}; \
		if [ -z "$$d" ]; then \
			echo "gt-be98-vendor-firmware: FW_$${g}_DIR not set, skipping $$dst" >&2; \
			continue; fi; \
		f=$$d/$$src; \
		[ -f "$$f" ] || { echo "missing firmware $$f" >&2; exit 1; }; \
		echo "$$sum  $$f" | sha256sum -c --quiet - || \
			{ echo "sha256 mismatch: $$f" >&2; exit 1; }; \
		$(INSTALL) -D -m 0644 $$f $(TARGET_DIR)/lib/firmware/$$dst; \
	done
endef

$(eval $(generic-package))

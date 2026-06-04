################################################################################
#
# gt-be98-samba
#
# ASUS Samba (samba_multicall + smbd/nmbd/smbpasswd symlinks). Self-contained
# prebuilt ARM blob (glibc deps only) from gt-be98-packages.
#
################################################################################

GT_BE98_SAMBA_VERSION = 1.0
GT_BE98_SAMBA_SITE = https://github.com/nebuloss/gt-be98-packages/releases/download/samba-$(GT_BE98_SAMBA_VERSION)
GT_BE98_SAMBA_SOURCE = gt-be98-samba-$(GT_BE98_SAMBA_VERSION).tar.gz
GT_BE98_SAMBA_LICENSE = PROPRIETARY
GT_BE98_SAMBA_REDISTRIBUTE = NO

# Install the fs.install subtree onto the target root (cp -a preserves the
# smbd/nmbd/smbpasswd -> samba_multicall symlinks).
define GT_BE98_SAMBA_INSTALL_TARGET_CMDS
	cp -a `find $(@D) -type d -name fs.install | head -1`/. $(TARGET_DIR)/
endef

$(eval $(generic-package))

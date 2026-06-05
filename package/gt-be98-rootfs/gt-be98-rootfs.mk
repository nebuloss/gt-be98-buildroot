################################################################################
#
# gt-be98-rootfs
#
# Merlin's FINAL ASUS GT-BE98 rootfs.img (built squashfs, content-identical to a
# working merlin flash). Provided to board/gt-be98/post-image-full.sh, which uses
# it verbatim as rootfs.squashfs (no rebuild) — so the .pkgtb matches the stock
# firmware. Customize via /jffs + nvram (both persist across flashes), not by
# rebuilding the proprietary userspace.
#
# Version 0031 = extracted from the VALIDATED artifact (the 0001-0031 pkgtb
# flashed and running on the device, sha256 a7dcd0c1…fa01) via
# gt-be98-packages/scripts/extract-pkgtb.sh — embedded rootfs sha256
# dfbf98b4d3a474887ad029e9e6347da081f013e615a607f4f083bb2f3ab28d2c.
#
################################################################################

GT_BE98_ROOTFS_VERSION = 0031
GT_BE98_ROOTFS_SITE = https://github.com/nebuloss/gt-be98-packages/releases/download/rootfs-$(GT_BE98_ROOTFS_VERSION)
GT_BE98_ROOTFS_SOURCE = gt-be98-rootfs-$(GT_BE98_ROOTFS_VERSION).tar.gz
GT_BE98_ROOTFS_LICENSE = PROPRIETARY
GT_BE98_ROOTFS_REDISTRIBUTE = NO

# Don't install to the Buildroot target: this blob is a complete rootfs.img
# (squashfs), used directly by post-image-full.sh as rootfs.squashfs. The package
# only fetches+extracts it so post-image can find it under $(BUILD_DIR).

$(eval $(generic-package))

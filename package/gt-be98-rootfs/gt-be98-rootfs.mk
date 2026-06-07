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
# Version 0034 = the Phase-2b blob set (patches 0024-0031 + 0033 + 0034; 0032
# deliberately excluded), built from scratch 2026-06-06 on pinned upstream
# ad42d5e81a53. Sourced from gt-be98-firmware/artifacts-0034/rootfs.img,
# byte-identical to the squashfs embedded in the artifacts-0034 update pkgtb
# (sha256 1711c65e…7825, verified via dumpimage FIT hashes) — embedded rootfs
# sha256 76d4ad9e307383a323ce3f01f0e0d7ba83023bd01ecfb3c25d68e456926935cf.
# NB the gtbe98_httpd/gtbe98_sched_daemon gates are default-OFF in this blob:
# no stock :80 UI until the open webui owns management (P2-5/P2-6).
#
################################################################################

GT_BE98_ROOTFS_VERSION = 0034
GT_BE98_ROOTFS_SITE = https://github.com/nebuloss/gt-be98-packages/releases/download/rootfs-$(GT_BE98_ROOTFS_VERSION)
GT_BE98_ROOTFS_SOURCE = gt-be98-rootfs-$(GT_BE98_ROOTFS_VERSION).tar.gz
GT_BE98_ROOTFS_LICENSE = PROPRIETARY
GT_BE98_ROOTFS_REDISTRIBUTE = NO

# Don't install to the Buildroot target: this blob is a complete rootfs.img
# (squashfs), used directly by post-image-full.sh as rootfs.squashfs. The package
# only fetches+extracts it so post-image can find it under $(BUILD_DIR).

$(eval $(generic-package))

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
# Version 0035 = blob-0034 lineage (patches 0024-0031 + 0033 + 0034; 0032
# deliberately excluded — banned envrams-wrapper) PLUS patch 0035 (watchdog
# gtbe98_wifi_extsup gate of the debug_monitor/hostapd respawn, default-OFF;
# the gate to the open-wifi-sole-supervisor OS) AND the patch-0029 tighter
# re-apply: the wlc_nt_enable gate now lands ONLY in start_wlc_nt() (not the
# near-twin start_wlceventd/start_wlc_monitor as it did in blob 0034) — so a
# fresh image no longer needs the nvram wlc_nt_enable=1 workaround for wlceventd.
# Built ./build.sh clean 2026-06-07 on pinned upstream ad42d5e81a53. Sourced from
# gt-be98-firmware/artifacts-0035/rootfs.img — embedded rootfs sha256
# c9d4e776a63ad245b35d46567e5382c35d3b786112db848d07a93ce8f7abb1b6.
# NB the gtbe98_httpd/gtbe98_sched_daemon gates remain default-OFF in this blob:
# no stock :80 UI until the open webui owns management (P2-5/P2-6).
#
################################################################################

GT_BE98_ROOTFS_VERSION = 0035
GT_BE98_ROOTFS_SITE = https://github.com/nebuloss/gt-be98-packages/releases/download/rootfs-$(GT_BE98_ROOTFS_VERSION)
GT_BE98_ROOTFS_SOURCE = gt-be98-rootfs-$(GT_BE98_ROOTFS_VERSION).tar.gz
GT_BE98_ROOTFS_LICENSE = PROPRIETARY
GT_BE98_ROOTFS_REDISTRIBUTE = NO

# Don't install to the Buildroot target: this blob is a complete rootfs.img
# (squashfs), used directly by post-image-full.sh as rootfs.squashfs. The package
# only fetches+extracts it so post-image can find it under $(BUILD_DIR).

$(eval $(generic-package))

#!/bin/sh
# build-initramfs-dhd.sh — CP-1.
# Assemble the "dhd" initramfs: the static aarch64 PID1 (rootfs/init.c) + the
# closed dhd.ko and its full dep chain + cfg80211.ko, so that under the HARNESS
# kernel (which exports the 70 merlin-only vmlinux symbols dhd's deps need) the
# init can finit_module the whole chain and attempt `insmod dhd.ko` against the
# emulated Broadcom PCIe device-model.
#
# The 32-bit-ARM device busybox is NOT usable here (the harness kernel is
# aarch64); the static aarch64 init is the only userspace needed.
set -e
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/scripts/config.env"

export ARCH=arm64
export CROSS_COMPILE="$CROSS"
export PATH=/usr/bin:/bin:"$TC"

# cfg80211.ko ships in the rootfs kernel/ tree, not in extra/
CFG80211="$MODDIR/../kernel/net/wireless/cfg80211.ko"

# 1. static aarch64 init
"${CROSS}gcc" -static -O2 -o "$HERE/rootfs/init" "$HERE/rootfs/init.c"

# 2. assemble the dhd initramfs
R="$HERE/rootfs/root-dhd"
rm -rf "$R"; mkdir -p "$R/proc" "$R/sys" "$R/dev"
cp "$HERE/rootfs/init" "$R/init"

# the dep chain + dhd (names match init.c's load list)
for m in bcm_knvram bcmlibs bdmf bcmmcast wlshared hnd rdpa_gpl \
         emf igs wfd bcm_enet bcm_pcie_hcd dhd; do
    if [ -f "$MODDIR/$m.ko" ]; then
        cp "$MODDIR/$m.ko" "$R/$m.ko"
    else
        echo "WARN: missing $MODDIR/$m.ko"
    fi
done
[ -f "$CFG80211" ] && cp "$CFG80211" "$R/cfg80211.ko" || echo "WARN: missing cfg80211.ko ($CFG80211)"

( cd "$R" && find . | cpio -o -H newc 2>/dev/null | gzip -9 ) > "$HERE/rootfs/initramfs-dhd.cpio.gz"
echo "initramfs: $HERE/rootfs/initramfs-dhd.cpio.gz"
ls -l "$HERE/rootfs/initramfs-dhd.cpio.gz"
echo "modules packed:"; ls "$R"/*.ko 2>/dev/null | xargs -n1 basename

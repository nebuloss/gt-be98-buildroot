#!/bin/busybox sh
# SPDX-License-Identifier: GPL-2.0
# Run ON THE STOCK FIRMWARE: put the mainline OS into slot 1, i.e. the boot
# FIT into UBI vol 3 "bootfs1" and the rootfs into vol 4 "rootfs1",
# resizing the volumes when needed (stock-side UBI operations, as for vol 3
# before). Nothing else is touched. Run from the kit directory (static
# ubinfo/ubirsvol/ubiupdatevol).
#
#   stock-slot1-flash.sh --check ROOTFS ROOTFS_SHA256 ITB ITB_SHA256 [VOL4_LEBS]
#   stock-slot1-flash.sh         ROOTFS ROOTFS_SHA256 ITB ITB_SHA256 [VOL4_LEBS]
#
# VOL4_LEBS: the size to give vol 4 (default 265 LEBs = 32.1 MiB: the rootfs
# (~228 LEBs today) plus headroom for its growth). vol 3 is grown only if
# the FIT does not fit. Refuses if the UBI device does not have the free
# LEBs. Checks the inputs before and the volume contents after.
set -eu
K=$(cd "$(dirname "$0")" && pwd)
LEB=126976
CHECK=0
[ "${1:-}" = --check ] && { CHECK=1; shift; }
[ $# -ge 4 ] || { sed -n '9,10p' "$0"; exit 1; }
RFS=$1 RSHA=$2 ITB=$3 ISHA=$4 V4=${5:-265}
t() { if [ -x "$K/$1" ]; then echo "$K/$1"; else echo "$1"; fi; }
[ -n "${SLOT1_REHEARSAL:-}" ] || grep -q "ubi.block=" /proc/cmdline || { echo "not the stock firmware"; exit 1; }
die() { echo "stock-slot1-flash: $*"; exit 1; }
v() { cat /sys/class/ubi/ubi0_$1/$2; }

[ "$(sha256sum "$RFS" | cut -d' ' -f1)" = "$RSHA" ] || die "$RFS: sha256 mismatch"
[ "$(sha256sum "$ITB" | cut -d' ' -f1)" = "$ISHA" ] || die "$ITB: sha256 mismatch"
[ "$(head -c 4 "$RFS")" = hsqs ] || die "$RFS is not a squashfs (U-Boot checks vol 4's magic)"
[ "$(v 3 name)" = bootfs1 ] && [ "$(v 4 name)" = rootfs1 ] || die "vol 3/4 are not bootfs1/rootfs1"
rsize=$(wc -c < "$RFS"); isize=$(wc -c < "$ITB")
rneed=$(( (rsize + LEB - 1) / LEB )); ineed=$(( (isize + LEB - 1) / LEB ))
[ "$V4" -ge "$rneed" ] || die "VOL4_LEBS $V4 < the $rneed LEBs the rootfs needs"
avail=$(cat /sys/class/ubi/ubi0/avail_eraseblocks)
v4now=$(v 4 reserved_ebs); v3now=$(v 3 reserved_ebs)
d4=0; [ "$V4" -gt "$v4now" ] && d4=$((V4 - v4now))
d3=0; [ "$ineed" -gt "$v3now" ] && d3=$((ineed - v3now))
echo "UBI: $avail free LEBs; vol 3 bootfs1 $v3now LEBs (FIT needs $ineed), vol 4 rootfs1 $v4now LEBs (rootfs needs $rneed, target $V4)"
echo "plan: vol 4 -> $V4 LEBs (+$d4), vol 3 +$d3; free afterwards: $((avail - d4 - d3)) LEBs"
[ $((d4 + d3)) -le "$avail" ] || die "not enough free LEBs ($((d4 + d3)) needed, $avail free)"
[ $CHECK = 1 ] && { echo "check only: nothing written"; exit 0; }

if [ "$V4" -ne "$v4now" ]; then
	$(t ubirsvol) /dev/ubi0 -n 4 -S "$V4"
fi
$(t ubiupdatevol) /dev/ubi0_4 "$RFS"
got=$(head -c "$rsize" /dev/ubi0_4 | sha256sum | cut -d' ' -f1)
[ "$got" = "$RSHA" ] || die "vol 4 read back: sha256 $got (want $RSHA)"
echo "vol 4 rootfs1: $rsize B written, read back OK"
[ $d3 = 0 ] || $(t ubirsvol) /dev/ubi0 -n 3 -S "$ineed"
$(t ubiupdatevol) /dev/ubi0_3 "$ITB"
got=$(sha256sum /dev/ubi0_3 | cut -d' ' -f1)
[ "$got" = "$ISHA" ] || die "vol 3 read back: sha256 $got (want $ISHA)"
echo "vol 3 bootfs1: $isize B written, read back OK"
sync
echo "done: free LEBs now $(cat /sys/class/ubi/ubi0/avail_eraseblocks); trial boot with: bcm_bootstate 3; reboot"

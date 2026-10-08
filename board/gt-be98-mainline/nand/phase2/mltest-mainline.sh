#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# G7 on the MAINLINE OS (NAND-PHASE2.md). Needs an image built with
# NAND=rw-jffs and, in /etc/conf.d/gt-be98-jffs, JFFS_MODE=rw and
# FENCE_VOLUMES=mltest (then "rc-service gt-be98-jffs restart"): UBI is
# attached with the write fence on mltest only (/jffs stays read-only).
#
#   mltest-mainline.sh write-a      write patternA.bin into mltest (gt-be98-ubileb)
#   mltest-mainline.sh verify-b     check the pattern stock wrote (patternB.bin)
#   mltest-mainline.sh status       fence state and counters
set -eu
K=$(cd "$(dirname "$0")" && pwd)
LEB=126976
FD=/sys/kernel/debug/ubi/ubi0/fence
vol_id() { ubinfo -d 0 -N mltest 2>/dev/null | sed -n 's/^Volume ID: *\([0-9]*\).*/\1/p'; }
want() { grep " $1\$" "$K/SHA256SUMS" | cut -d' ' -f1; }
grep -q '^state active' $FD || { echo "UBI write fence not active"; exit 1; }
grep -q '^volumes mltest:' $FD || { echo "the fence must cover mltest ONLY (FENCE_VOLUMES=mltest)"; exit 1; }
case "${1:-status}" in
write-a)
	v=$(vol_id)
	"$K/gt-be98-ubileb" write /dev/ubi0_$v "$K/patternA.bin"
	n=$(( $(wc -c < "$K/patternA.bin") / LEB ))
	got=$(dd if=/dev/ubi0_$v bs=$LEB count=$n 2>/dev/null | sha256sum | cut -d' ' -f1)
	[ "$got" = "$(want patternA.bin)" ] && echo "patternA written and read back: OK" || { echo "READBACK MISMATCH"; exit 2; }
	cat $FD ;;
verify-b)
	v=$(vol_id); n=$(( $(wc -c < "$K/patternB.bin") / LEB ))
	got=$(dd if=/dev/ubi0_$v bs=$LEB count=$n 2>/dev/null | sha256sum | cut -d' ' -f1)
	[ "$got" = "$(want patternB.bin)" ] && echo "G7 mainline reads stock's pattern: OK" || { echo "G7 MISMATCH: $got"; exit 2; } ;;
status) cat $FD; gt-be98-nandcheck | sed -n '/== mtd sysfs/,/== nand kernel log/p' ;;
*) echo "usage: $0 write-a|verify-b|status"; exit 1 ;;
esac

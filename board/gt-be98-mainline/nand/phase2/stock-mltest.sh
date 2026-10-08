#!/bin/busybox sh
# SPDX-License-Identifier: GPL-2.0
# G7 on the STOCK firmware (NAND-PHASE2.md): the sacrificial UBI volume
# "mltest" that mainline is allowed to write first (fence=mltest).
#
#   stock-mltest.sh create          ubimkvol mltest, 2 MiB (17 LEBs), dynamic
#   stock-mltest.sh verify-a        check the pattern mainline wrote (patternA.bin)
#   stock-mltest.sh write-b         write patternB.bin (stock driver) for mainline to read
#   stock-mltest.sh remove          ubirmvol mltest
# Run from the kit directory (patternA.bin, patternB.bin, SHA256SUMS).
set -eu
K=$(cd "$(dirname "$0")" && pwd)
LEB=126976
vol_id() { ubinfo -d 0 -N mltest 2>/dev/null | sed -n 's/^Volume ID: *\([0-9]*\).*/\1/p'; }
want() { grep " $1\$" "$K/SHA256SUMS" | cut -d' ' -f1; }
grep -q 'ubi.block=' /proc/cmdline || { echo "not the stock firmware"; exit 1; }
case "${1:-}" in
create)
	[ -z "$(vol_id)" ] || { echo "mltest exists already (id $(vol_id))"; exit 1; }
	ubimkvol /dev/ubi0 -N mltest -s 2MiB -t dynamic
	echo "mltest = /dev/ubi0_$(vol_id)"; ubinfo -d 0 -N mltest ;;
verify-a)
	v=$(vol_id); n=$(( $(wc -c < "$K/patternA.bin") / LEB ))
	got=$(dd if=/dev/ubi0_$v bs=$LEB count=$n 2>/dev/null | sha256sum | cut -d' ' -f1)
	[ "$got" = "$(want patternA.bin)" ] && echo "G7 stock reads mainline's pattern: OK" ||
		{ echo "G7 MISMATCH: $got"; exit 2; } ;;
write-b)
	v=$(vol_id)
	ubiupdatevol /dev/ubi0_$v "$K/patternB.bin"
	echo "patternB written by stock to /dev/ubi0_$v" ;;
remove)
	v=$(vol_id); [ -n "$v" ] || { echo "no mltest"; exit 0; }
	ubirmvol /dev/ubi0 -n $v && echo "mltest removed" ;;
*) echo "usage: $0 create|verify-a|write-b|remove"; exit 1 ;;
esac

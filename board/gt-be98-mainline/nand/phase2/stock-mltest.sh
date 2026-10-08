#!/bin/busybox sh
# SPDX-License-Identifier: GPL-2.0
# G7 on the STOCK firmware (NAND-PHASE2.md, phase2/G7.md): the sacrificial
# UBI volume "mltest", the only volume mainline may write in this step.
#
#   stock-mltest.sh create      ubimkvol mltest, 2 MiB, dynamic (refuses if it exists)
#   stock-mltest.sh write-a     write patternA.bin (stock driver), read back
#   stock-mltest.sh verify-a    check patternA.bin
#   stock-mltest.sh write-b     write patternB.bin (stock driver), read back
#   stock-mltest.sh verify-b    check patternB.bin (written by mainline)
#   stock-mltest.sh flips       raw vs corrected read of every mltest PEB:
#                               PASS = at most 1 bitflip per 512-B sector
#   stock-mltest.sh remove      ubirmvol mltest
# Run from the kit directory (static ubinfo/ubimkvol/ubirmvol/gt-be98-ubileb,
# patternA.bin, patternB.bin, SHA256SUMS). Writes use the atomic LEB change
# ioctl (gt-be98-ubileb), the same path as on mainline.
set -eu
K=$(cd "$(dirname "$0")" && pwd)
LEB=126976
t() { if [ -x "$K/$1" ]; then echo "$K/$1"; else echo "$1"; fi; }
vol_id() { $(t ubinfo) -d 0 -N mltest 2>/dev/null | sed -n 's/^Volume ID: *\([0-9]*\).*/\1/p'; }
want() { grep " $1\$" "$K/SHA256SUMS" | cut -d' ' -f1; }
check() {	# $1 pattern file: sha256 of the first LEBs of mltest
	v=$(vol_id); [ -n "$v" ] || { echo "no mltest volume"; exit 1; }
	n=$(( $(wc -c < "$K/$1") / LEB ))
	got=$(dd if=/dev/ubi0_$v bs=$LEB count=$n 2>/dev/null | sha256sum | cut -d' ' -f1)
	if [ "$got" = "$(want "$1")" ]; then
		echo "G7 stock reads $1 from /dev/ubi0_$v: OK"
	else
		echo "G7 MISMATCH on $1: got $got want $(want "$1")"; exit 2
	fi
}
flips() {	# $1 nanddump, $2 nandtool, $3 /dev/mtdN, $4 mltest volume id
	fw=${W:-/tmp/g7}/flips; mkdir -p "$fw"; : > "$fw/raw"; : > "$fw/ecc"
	"$2" pebmap "$3" > "$fw/pebmap"
	pebs=$(awk -v v="$4" '$3 == "vol" && $4 == v { print $2 }' "$fw/pebmap")
	[ -n "$pebs" ] || { echo "no mltest PEBs"; exit 1; }
	for p in $pebs; do
		"$1" -q -n --oob -s $((p * 131072)) -l 131072 -f "$fw/r" "$3"; cat "$fw/r" >> "$fw/raw"
		"$1" -q --oob -s $((p * 131072)) -l 131072 -f "$fw/e" "$3"; cat "$fw/e" >> "$fw/ecc"
	done
	"$2" flips "$fw/raw" "$fw/ecc" 2048 "$(cat /sys/class/mtd/${3#/dev/}/oobsize)" > "$fw/flips.txt"
	worst=$(sed -n 's/.*worst_sector \([0-9]*\).*/\1/p' "$fw/flips.txt")
	echo "mltest PEBs: $(echo $pebs)"; tail -n 1 "$fw/flips.txt"
	if [ "${worst:-99}" -le 1 ]; then echo "G7-FLIPS PASS: worst sector $worst bit(s)"; else echo "G7-FLIPS FAIL: worst sector ${worst:-?} bits (> 1)"; exit 2; fi
}
# G7_REHEARSAL=1: the nandsim rehearsal (an unfenced attach stands for stock)
[ -n "${G7_REHEARSAL:-}" ] || grep -q 'ubi.block=' /proc/cmdline || { echo "not the stock firmware"; exit 1; }
case "${1:-}" in
create)
	[ -z "$(vol_id)" ] || { echo "mltest exists already (id $(vol_id))"; exit 1; }
	$(t ubimkvol) /dev/ubi0 -N mltest -s 2MiB -t dynamic
	echo "mltest = /dev/ubi0_$(vol_id)"; $(t ubinfo) -d 0 -N mltest ;;
write-a|write-b)
	p=pattern$(echo "${1#write-}" | tr ab AB).bin
	v=$(vol_id); [ -n "$v" ] || { echo "no mltest volume"; exit 1; }
	"$K/gt-be98-ubileb" write /dev/ubi0_$v "$K/$p"
	sync; check "$p" ;;
verify-a) check patternA.bin ;;
verify-b) check patternB.bin ;;
flips)
	v=$(vol_id); [ -n "$v" ] || { echo "no mltest volume"; exit 1; }
	m=${G7_MTD:-/dev/mtd$(sed -n 's/^mtd\([0-9]*\): .* "image"$/\1/p' /proc/mtd | head -n1)}
	flips "$K/nanddump" "$K/gt-be98-nandtool" "$m" "$v" ;;
remove)
	v=$(vol_id); [ -n "$v" ] || { echo "no mltest"; exit 0; }
	$(t ubirmvol) /dev/ubi0 -n "$v" && echo "mltest removed" ;;
*) echo "usage: $0 create|write-a|verify-a|write-b|verify-b|flips|remove"; exit 1 ;;
esac

#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# G7 on the MAINLINE OS (NAND-PHASE2.md, phase2/G7.md). Needs the G7 itb
# (NAND=rw-jffs) and, in /etc/conf.d/gt-be98-jffs, FENCE_VOLUMES=mltest with
# JFFS_MODE=ro (then "rc-service gt-be98-jffs restart"): UBI attached with
# the write fence on mltest only; /jffs read-only.
#
#   mltest-mainline.sh verify-a     check the pattern stock wrote (patternA.bin)
#   mltest-mainline.sh write-b      write patternB.bin into mltest, read back
#   mltest-mainline.sh verify-b     check patternB.bin
#   mltest-mainline.sh write-a      write patternA.bin (other direction, if needed)
#   mltest-mainline.sh status       fence state and counters, NAND counters
#   mltest-mainline.sh before       BEFORE the fenced attach (phase-1 state):
#                                   PEB owner map + corrected dump of "image" to $W
#   mltest-mainline.sh after        AFTER "rc-service gt-be98-jffs stop" (UBI
#                                   detached): dump again, list every changed
#                                   PEB with its owner; PASS = only mltest + free
# W (default /tmp/g7) needs ~530 MB of RAM.
set -eu
K=$(cd "$(dirname "$0")" && pwd)
LEB=126976
FD=/sys/kernel/debug/ubi/ubi0/fence
vol_id() { ubinfo -d 0 -N mltest 2>/dev/null | sed -n 's/^Volume ID: *\([0-9]*\).*/\1/p'; }
want() { grep " $1\$" "$K/SHA256SUMS" | cut -d' ' -f1; }
check() {
	v=$(vol_id); [ -n "$v" ] || { echo "no mltest volume"; exit 1; }
	n=$(( $(wc -c < "$K/$1") / LEB ))
	got=$(dd if=/dev/ubi0_$v bs=$LEB count=$n 2>/dev/null | sha256sum | cut -d' ' -f1)
	if [ "$got" = "$(want "$1")" ]; then
		echo "G7 mainline reads $1 from /dev/ubi0_$v: OK"
	else
		echo "G7 MISMATCH on $1: got $got want $(want "$1")"; exit 2
	fi
}
W=${W:-/tmp/g7}
mtd_of() { sed -n "s/^mtd\([0-9]*\): [0-9a-f]* [0-9a-f]* \"$1\"\$/\1/p" /proc/mtd | head -n1; }
M=${G7_MTD:-/dev/mtd$(mtd_of image)}	# G7_MTD: the nandsim rehearsal
case "${1:-status}" in
before)
	[ "$(cat /sys/module/brcmnand/parameters/allow_write 2>/dev/null || echo N)" = N ] || { echo "allow_write is on: run this before enabling the fence"; exit 1; }
	[ -e /sys/class/ubi/ubi0 ] || { echo "UBI not attached (phase-1 read-only attach expected)"; exit 1; }
	mkdir -p "$W"
	vol_id > "$W/mltest.id"; [ -s "$W/mltest.id" ] || { echo "no mltest volume (stock-mltest.sh create first)"; exit 1; }
	"$K/gt-be98-nandtool" pebmap "$M" > "$W/pebmap.before"
	nanddump -q --bb=dumpbad -f "$W/before.data" "$M"
	echo "before: $(wc -c < "$W/before.data") B, mltest = vol $(cat "$W/mltest.id"), $(grep -c "vol $(cat "$W/mltest.id") " "$W/pebmap.before") mltest PEBs"
	exit 0 ;;
after)
	[ ! -e /sys/class/ubi/ubi0 ] || { echo "detach first: rc-service gt-be98-jffs stop"; exit 1; }
	[ -f "$W/before.data" ] || { echo "no $W/before.data"; exit 1; }
	nanddump -q --bb=dumpbad -f "$W/after.data" "$M"
	"$K/gt-be98-nandtool" pebdiff "$W/before.data" "$W/after.data" 131072 "$W/pebmap.before" > "$W/pebdiff.txt"
	id=$(cat "$W/mltest.id")
	grep '^changed' "$W/pebdiff.txt"; tail -n 1 "$W/pebdiff.txt"
	if grep -q 'other 0' "$W/pebdiff.txt" &&
	   ! grep '^changed' "$W/pebdiff.txt" | grep -vqE "\((free|vol $id lnum [0-9]+)\)"; then
		echo "G7-PEBDIFF PASS: only mltest (vol $id) and free PEBs changed"
	else
		echo "G7-PEBDIFF FAIL: a PEB outside mltest/free changed"; exit 2
	fi
	exit 0 ;;
esac
grep -q '^state active' $FD 2>/dev/null || { echo "UBI write fence not active"; exit 1; }
grep -qx "volumes mltest:[0-9]*" $FD || { echo "the fence must cover mltest ONLY (FENCE_VOLUMES=mltest)"; grep '^volumes' $FD; exit 1; }
case "${1:-status}" in
verify-a) check patternA.bin ;;
verify-b) check patternB.bin ;;
write-a|write-b)
	p=pattern$(echo "${1#write-}" | tr ab AB).bin
	v=$(vol_id); [ -n "$v" ] || { echo "no mltest volume"; exit 1; }
	"$K/gt-be98-ubileb" write /dev/ubi0_$v "$K/$p"
	sync; check "$p"; cat $FD ;;
status)
	cat $FD
	echo "allow_write $(cat /sys/module/brcmnand/parameters/allow_write 2>/dev/null)"
	for m in /sys/class/mtd/mtd[0-9]*; do
		case "$m" in *ro) continue ;; esac
		echo "${m##*/} $(cat $m/name) flags $(cat $m/flags) corrected_bits $(cat $m/corrected_bits 2>/dev/null) ecc_failures $(cat $m/ecc_failures 2>/dev/null) bad_blocks $(cat $m/bad_blocks 2>/dev/null)"
	done
	grep ' /jffs ' /proc/mounts ;;
*) echo "usage: $0 before|verify-a|write-b|verify-b|write-a|status|after"; exit 1 ;;
esac

#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# Run ON THE STOCK FIRMWARE (4.19), read-only: prints the NAND/UBI facts the
# mainline OS must match, in the same sections as gt-be98-nandcheck.
#
#   scp stock-nandinfo.sh <stock>:/tmp/ && ssh <stock> '/bin/busybox sh /tmp/stock-nandinfo.sh' > stock-nand.txt
#
# Nothing here writes: devmem only READS the NAND controller configuration
# registers (0xff801800..0xff80187c: revision, CS select, CS0 ACC_CONTROL /
# CONFIG / TIMING), never the FIFO, cache or command registers.
echo "== kernel"
uname -a
cat /proc/cmdline
echo "== /proc/mtd"
cat /proc/mtd
echo "== mtd sysfs (name type size erasesize writesize oobsize ecc_strength ecc_step_size flags corrected_bits ecc_failures bad_blocks bbt_blocks)"
for m in /sys/class/mtd/mtd[0-9]*; do
	case "$m" in *ro) continue ;; esac
	[ -f "$m/name" ] || continue
	echo "${m##*/} $(cat $m/name) $(cat $m/type) $(cat $m/size) $(cat $m/erasesize) $(cat $m/writesize) $(cat $m/oobsize) $(cat $m/ecc_strength 2>/dev/null) $(cat $m/ecc_step_size 2>/dev/null) $(cat $m/flags) $(cat $m/corrected_bits 2>/dev/null) $(cat $m/ecc_failures 2>/dev/null) $(cat $m/bad_blocks 2>/dev/null) $(cat $m/bbt_blocks 2>/dev/null)"
done
echo "== nand kernel log"
dmesg | grep -iE 'brcmnand|nand|bbt|bad block|ecc|ubi[0-9]?:|ubifs' | head -n 80
echo "== ubi"
ubinfo -a 2>/dev/null || echo "(no ubinfo)"
for v in /sys/class/ubi/ubi0_*; do
	[ -f "$v/name" ] || continue
	echo "${v##*_} $(cat $v/name) $(cat $v/type) $(cat $v/reserved_ebs) $(cat $v/data_bytes) $(cat $v/corrupted) $(cat $v/upd_marker)"
done
echo "-- sha256 of the static volumes"
for v in /sys/class/ubi/ubi0_*; do
	[ "$(cat $v/type 2>/dev/null)" = static ] || continue
	n=${v##*/}
	echo "$n $(cat $v/name) $(sha256sum /dev/$n | cut -d' ' -f1)"
done
echo "== mounts"
grep -E 'ubi|jffs|/data' /proc/mounts
echo "== NAND controller config registers (read-only)"
for o in 0x00 0x04 0x08 0x0c 0x14 0x18 0x1c 0x50 0x54 0x58 0x5c 0x60 0x64 0x68 0x6c 0x70 0x74 0x78 0x7c; do
	echo "0xff8018${o#0x}: $(devmem $((0xff801800 + o)) 32 2>/dev/null)"
done
echo "== nand device-tree node"
for p in /proc/device-tree/periph/nand/* /proc/device-tree/periph/nand/nandcs@0/*; do
	[ -f "$p" ] && echo "$p: $(od -An -tx1 "$p" | tr -d '\n' | cut -c1-120)"
done
echo "== tools"
for t in nanddump ubinfo mtdinfo; do printf '%s: %s\n' $t "$(command -v $t || echo missing)"; done
echo "== /jffs"
ls -la /jffs/mainline-os 2>/dev/null || echo "(no /jffs/mainline-os)"
df -k /jffs 2>/dev/null

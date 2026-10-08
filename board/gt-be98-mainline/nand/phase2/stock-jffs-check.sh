#!/bin/busybox sh
# SPDX-License-Identifier: GPL-2.0
# G8 on the STOCK firmware (NAND-PHASE2.md, phase2/G8.md), after the first
# mainline read-write session on /jffs:
#
#   stock-jffs-check.sh read     /jffs mounted rw by stock; the files mainline
#                                wrote are there and intact (g8-test/marker.bin
#                                = patternA.bin, state.tgz = its .sha256)
#   stock-jffs-check.sh write    stock writes, reads back and deletes a test
#                                file on /jffs (patternB.bin)
#   stock-jffs-check.sh clean    remove /jffs/mainline-os/g8-test
# Run from the kit directory. G8_JFFS: rehearsal only.
set -eu
K=$(cd "$(dirname "$0")" && pwd)
J=${G8_JFFS:-/jffs}
want() { grep " $1\$" "$K/SHA256SUMS" | cut -d' ' -f1; }
[ -n "${G8_REHEARSAL:-}" ] || grep -q 'ubi.block=' /proc/cmdline || { echo "not the stock firmware"; exit 1; }
case "${1:-}" in
read)
	fail=0
	grep -E " $J ubifs rw" /proc/mounts || { echo "$J not mounted read-write by stock: FAIL"; fail=1; }
	ls -la "$J/mainline-os" "$J/mainline-os/g8-test" 2>&1 || true
	got=$(sha256sum "$J/mainline-os/g8-test/marker.bin" 2>/dev/null | cut -d' ' -f1)
	[ "$got" = "$(want patternA.bin)" ] && echo "marker.bin (written by mainline): OK" ||
		{ echo "marker.bin: ${got:-missing}: FAIL"; fail=1; }
	if [ -f "$J/mainline-os/state.tgz.sha256" ]; then
		w=$(cut -d' ' -f1 "$J/mainline-os/state.tgz.sha256")
		g=$(sha256sum "$J/mainline-os/state.tgz" 2>/dev/null | cut -d' ' -f1)
		[ "$w" = "$g" ] && echo "state.tgz (gt-be98-save --local): OK" || { echo "state.tgz sha256 mismatch: FAIL"; fail=1; }
		tar -tzf "$J/mainline-os/state.tgz" > /dev/null && echo "state.tgz readable: OK" || { echo "state.tgz unreadable: FAIL"; fail=1; }
	else
		echo "no state.tgz.sha256: FAIL"; fail=1
	fi
	dmesg | grep -iE 'ubifs (error|warning)|ubi[0-9]* (error|warning)' && { echo "UBI/UBIFS errors in dmesg: FAIL"; fail=1; }
	[ $fail = 0 ] && echo "G8-STOCK-READ PASS" || { echo "G8-STOCK-READ FAIL"; exit 2; } ;;
write)
	cp "$K/patternB.bin" "$J/g8-stock-test.bin"
	sync
	echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
	got=$(sha256sum "$J/g8-stock-test.bin" | cut -d' ' -f1)
	rm -f "$J/g8-stock-test.bin"; sync
	[ "$got" = "$(want patternB.bin)" ] && echo "G8-STOCK-WRITE PASS: stock wrote, read back and deleted a file on $J" ||
		{ echo "G8-STOCK-WRITE FAIL: $got"; exit 2; } ;;
clean)
	rm -rf "$J/mainline-os/g8-test"; sync; echo "g8-test removed" ;;
*) echo "usage: $0 read|write|clean"; exit 1 ;;
esac

#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# G8 on the MAINLINE OS (NAND-PHASE2.md, phase2/G8.md): the real /jffs
# read-write through the UBI write fence on jffs2 only. Needs the rw-jffs
# itb (the G7 itb) and, in /etc/conf.d/gt-be98-jffs, FENCE_VOLUMES=jffs2 and
# JFFS_MODE=rw (then "rc-service gt-be98-jffs restart").
#
#   jffs-mainline.sh before     BEFORE the fenced attach (phase-1 state, /jffs
#                               read-only): PEB owner map + corrected dump of
#                               "image", jffs2 superblock (LEB 0) sha256, sha256
#                               of every /jffs file, to $W
#   jffs-mainline.sh check      fence active on jffs2 ONLY, allow_write Y, /jffs rw
#   jffs-mainline.sh test       write the test file (patternA.bin) under
#                               /jffs/mainline-os/g8-test, sync, read back
#   jffs-mainline.sh loop [N]   N (default 20) x 1 MiB write+sync+delete there
#   jffs-mainline.sh verify     still fenced: superblock unchanged, every /jffs
#                               file outside mainline-os/ unchanged, test file OK
#   jffs-mainline.sh status     fence state and counters, NAND counters, mount
#   jffs-mainline.sh after      AFTER "cd /; rc-service gt-be98-jffs stop" (UBI
#                               detached): dump again, list every changed PEB
#                               with its owner; PASS = only jffs2 + free
# W (default /tmp/g8) needs ~530 MB of RAM. G8_JFFS / G8_MTD: rehearsal only.
set -eu
K=$(cd "$(dirname "$0")" && pwd)
LEB=126976
FD=/sys/kernel/debug/ubi/ubi0/fence
J=${G8_JFFS:-/jffs}
T=$J/mainline-os/g8-test
W=${W:-/tmp/g8}
mtd_of() { sed -n "s/^mtd\([0-9]*\): [0-9a-f]* [0-9a-f]* \"$1\"\$/\1/p" /proc/mtd | head -n1; }
M=${G8_MTD:-/dev/mtd$(mtd_of image)}
want() { grep " $1\$" "$K/SHA256SUMS" | cut -d' ' -f1; }
jid() { ubinfo -d 0 -N jffs2 2>/dev/null | sed -n 's/^Volume ID: *\([0-9]*\).*/\1/p'; }
sb() { dd if=/dev/ubi0_$(jid) bs=$LEB count=1 2>/dev/null | sha256sum | cut -d' ' -f1; }
files() {	# sha256 of every /jffs file outside mainline-os/
	(cd "$J" && find . -path ./mainline-os -prune -o -type f -print | sort | while read -r f; do
		sha256sum "$f"; done)
}
fenced() {
	grep -q '^state active' $FD 2>/dev/null || { echo "UBI write fence not active"; exit 1; }
	grep -qx "volumes jffs2:[0-9]*" $FD || { echo "the fence must cover jffs2 ONLY (FENCE_VOLUMES=jffs2)"; grep '^volumes' $FD; exit 1; }
}
rw() { grep -q " $J ubifs rw" /proc/mounts || { echo "$J is not mounted read-write (JFFS_MODE=rw)"; exit 1; }; }

case "${1:-status}" in
before)
	[ "$(cat /sys/module/brcmnand/parameters/allow_write 2>/dev/null || echo N)" = N ] ||
		{ echo "allow_write is on: run this before enabling the fence"; exit 1; }
	[ -e /sys/class/ubi/ubi0 ] || { echo "UBI not attached (phase-1 read-only attach expected)"; exit 1; }
	grep -q " $J ubifs ro" /proc/mounts || { echo "$J not mounted read-only"; exit 1; }
	mkdir -p "$W"
	jid > "$W/jffs2.id"; [ -s "$W/jffs2.id" ] || { echo "no jffs2 volume"; exit 1; }
	sb > "$W/sb.before"
	files > "$W/files.before"
	"$K/gt-be98-nandtool" pebmap "$M" > "$W/pebmap.before"
	nanddump -q --bb=dumpbad -f "$W/before.data" "$M"
	echo "before: $(wc -c < "$W/before.data") B, jffs2 = vol $(cat "$W/jffs2.id"), $(grep -c "vol $(cat "$W/jffs2.id") " "$W/pebmap.before") jffs2 PEBs, $(wc -l < "$W/files.before") files outside mainline-os/, superblock $(cut -c1-16 "$W/sb.before")"
	;;
check)
	fenced; rw
	[ "$(cat /sys/module/brcmnand/parameters/allow_write 2>/dev/null || echo Y)" = Y ] || { echo "allow_write is not Y"; exit 1; }
	grep -E '^(state|volumes|pebs|writes|mtd_gate)' $FD
	echo "G8-CHECK PASS: fence on jffs2 only, $J read-write" ;;
test)
	fenced; rw
	mkdir -p "$T"
	cp "$K/patternA.bin" "$T/marker.bin"
	sync
	echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
	got=$(sha256sum "$T/marker.bin" | cut -d' ' -f1)
	[ "$got" = "$(want patternA.bin)" ] && echo "G8-TEST PASS: $T/marker.bin written and read back" ||
		{ echo "G8-TEST FAIL: $got"; exit 2; } ;;
loop)
	fenced; rw
	n=${2:-20}; i=0
	mkdir -p "$T"
	while [ $i -lt "$n" ]; do
		dd if=/dev/urandom of="$T/loop.$i" bs=1048576 count=1 2>/dev/null
		sync
		rm -f "$T/loop.$i"
		sync
		i=$((i + 1))
	done
	grep -E '^(writes|mtd_gate)' $FD
	echo "G8-LOOP done: $n x 1 MiB" ;;
verify)
	fenced
	[ -f "$W/sb.before" ] || { echo "no $W/sb.before (run before first)"; exit 1; }
	fail=0
	[ "$(sb)" = "$(cat "$W/sb.before")" ] && echo "jffs2 superblock (LEB 0) unchanged: OK" ||
		{ echo "jffs2 superblock CHANGED: FAIL"; fail=1; }
	files > "$W/files.after"
	if cmp -s "$W/files.before" "$W/files.after"; then
		echo "$(wc -l < "$W/files.after") files outside mainline-os/ unchanged: OK"
	else
		echo "files outside mainline-os/ CHANGED: FAIL"; diff "$W/files.before" "$W/files.after" || true; fail=1
	fi
	got=$(sha256sum "$T/marker.bin" 2>/dev/null | cut -d' ' -f1)
	[ "$got" = "$(want patternA.bin)" ] && echo "test file: OK" || { echo "test file: FAIL"; fail=1; }
	[ $fail = 0 ] && echo "G8-VERIFY PASS" || { echo "G8-VERIFY FAIL"; exit 2; } ;;
status)
	cat $FD 2>/dev/null || echo "(no fence debugfs: UBI not attached?)"
	echo "allow_write $(cat /sys/module/brcmnand/parameters/allow_write 2>/dev/null)"
	for m in /sys/class/mtd/mtd[0-9]*; do
		case "$m" in *ro) continue ;; esac
		echo "${m##*/} $(cat $m/name) flags $(cat $m/flags) corrected_bits $(cat $m/corrected_bits 2>/dev/null) ecc_failures $(cat $m/ecc_failures 2>/dev/null) bad_blocks $(cat $m/bad_blocks 2>/dev/null)"
	done
	grep " $J " /proc/mounts || true
	df -k "$J" 2>/dev/null | tail -n 1
	ls -la "$J/mainline-os" 2>/dev/null || true ;;
after)
	[ ! -e /sys/class/ubi/ubi0 ] || { echo "detach first: cd /; rc-service gt-be98-jffs stop"; exit 1; }
	[ -f "$W/before.data" ] || { echo "no $W/before.data"; exit 1; }
	nanddump -q --bb=dumpbad -f "$W/after.data" "$M"
	"$K/gt-be98-nandtool" pebdiff "$W/before.data" "$W/after.data" 131072 "$W/pebmap.before" > "$W/pebdiff.txt"
	id=$(cat "$W/jffs2.id")
	grep '^changed' "$W/pebdiff.txt" | head -n 50; tail -n 1 "$W/pebdiff.txt"
	if grep -q 'other 0' "$W/pebdiff.txt" &&
	   ! grep '^changed' "$W/pebdiff.txt" | grep -vqE "\((free|vol $id lnum [0-9]+)\)"; then
		echo "G8-PEBDIFF PASS: only jffs2 (vol $id) and free PEBs changed"
	else
		echo "G8-PEBDIFF FAIL: a PEB outside jffs2/free changed"; exit 2
	fi ;;
*) echo "usage: $0 before|check|test|loop [N]|verify|status|after"; exit 1 ;;
esac

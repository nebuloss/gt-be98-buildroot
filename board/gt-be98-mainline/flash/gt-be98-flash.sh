#!/bin/busybox sh
# SPDX-License-Identifier: GPL-2.0
# gt-be98-flash.sh - put the GT-BE98 mainline OS into slot 1 from the STOCK
# firmware, and boot it once. docs/FLASHING.md is the procedure; this is the
# tool it calls. Run it with the stock busybox ("/bin/busybox sh", because
# /usr/sbin/sh on the stock firmware is a different program), from the kit
# directory (the static ubirsvol/ubiupdatevol next to it are used when present).
#
#   gt-be98-flash.sh status
#   gt-be98-flash.sh flash --check ROOTFS ROOTFS_SHA256 ITB ITB_SHA256 [VOL4_LEBS]
#   gt-be98-flash.sh flash         ROOTFS ROOTFS_SHA256 ITB ITB_SHA256 [VOL4_LEBS]
#   gt-be98-flash.sh boot [--check] [--clear-postcode] [--no-reboot]
#
# status  read-only: running OS, booted/committed slot, reset reason,
#         post-code byte, slot-1 volumes, free LEBs.
# flash   writes the rootfs into UBI vol 4 "rootfs1" and the boot FIT into
#         vol 3 "bootfs1" (slot 1), resizing them when needed, each read back
#         and sha256-checked. --check verifies everything and prints the plan,
#         writing nothing. VOL4_LEBS: size of vol 4 (default 265 LEBs = 32.1
#         MiB: the rootfs plus headroom for its growth). Nothing else is
#         written: not slot 2, not the slot metadata, not the bootloader.
# boot    arms the one-shot boot of slot 1 with the stock tool
#         ("bcm_bootstate 3"), checks that it took, and reboots. The committed
#         slot stays 2 (stock), so the NEXT reset of any kind, and every power
#         cycle, boots stock again. --check: only the preconditions.
#         --clear-postcode: first clears the post-code byte (bits [31:24] of
#         the boot-state register 0xff802628) so that a reading after a failed
#         boot is unambiguous: bits [23:0] are written back with the value just
#         read, and checked unchanged afterwards (the read-modify-write of the
#         stock-side post-code reader). Without it, nothing but bcm_bootstate
#         writes that register.
#
# Refuses unless: running the stock firmware from slot 2, slot 2 committed,
# slot-1 volumes named bootfs1/rootfs1 and not in use, inputs matching the
# given sha256s, enough free LEBs. The stock busybox has no "command"
# builtin and no "od": this uses which and hexdump.
#
# GT_BE98_FLASH_ROOT (tests only, test-gt-be98-flash.sh): a directory that
# stands for / (proc, sys, dev, data files); with it set, nothing reboots.
set -eu
K=$(cd "$(dirname "$0")" && pwd)
R=${GT_BE98_FLASH_ROOT:-}
BSR=0xff802628
LEB_GTBE98=126976

die() { echo "gt-be98-flash: $*" >&2; exit 1; }
say() { echo "gt-be98-flash: $*"; }
usage() { grep '^#   gt-be98-flash.sh' "$0" | sed 's/^# *//' >&2; exit 2; }
t() { if [ -x "$K/$1" ]; then echo "$K/$1"; else echo "$1"; fi; }
v() { cat "$R/sys/class/ubi/ubi0_$1/$2"; }
ubi() { cat "$R/sys/class/ubi/ubi0/$1"; }
is_stock() { grep -q "ubi.block=" "$R/proc/cmdline"; }
# booted slot from the kernel command line, the only reliable source
# (/proc/bootstate/active_image does not reflect it): 1, 2, or 0 = unknown
booted_slot() {
	case "$(cat "$R/proc/cmdline")" in
	*ubi.block=0,4*) echo 1 ;;
	*ubi.block=0,6*) echo 2 ;;
	*) echo 0 ;;
	esac
}
committed() { bcm_bootstate 2>/dev/null | grep -om1 'committed [0-9]' | sed 's/.* //'; }
rreason() { cat "$R/proc/bootstate/reset_reason" 2>/dev/null || echo unknown; }
hex32() { printf '0x%08X' "$(( $1 & 0xFFFFFFFF ))"; }
markers() { for f in /data/open_enet /data/.trial-armed; do [ ! -e "$R$f" ] || echo "$f"; done; }

need_stock_slot2() {
	is_stock || die "not the stock firmware (no ubi.block= on the kernel command line)"
	bs=$(booted_slot)
	[ "$bs" = 2 ] || die "stock is running from slot $bs, not slot 2: slot 1 would be the running system (docs/FLASHING.md, prerequisites)"
	which bcm_bootstate >/dev/null 2>&1 || die "bcm_bootstate missing: not the expected stock firmware"
	cs=$(committed)
	[ "$cs" = 2 ] || die "committed slot is '${cs:-unknown}', not 2: the way back to stock depends on slot 2 being committed"
}

cmd_status() {
	if is_stock; then
		echo "running: stock firmware $(uname -r), booted slot $(booted_slot)"
		bcm_bootstate 2>/dev/null | grep -iE 'commit|valid|seq|boot' || echo "bcm_bootstate: no output"
		echo "reset_reason: $(rreason) (34 = normal; 1 = one-shot boot of slot 1 armed)"
	else
		echo "running: not the stock firmware ($(uname -r)); on the mainline OS, 'reboot' returns to stock"
	fi
	if r=$(devmem $BSR 32 2>/dev/null); then
		printf 'boot-state register %s, post-code byte 0x%02x (board/gt-be98-mainline/README.md, post-codes)\n' \
			"$(hex32 "$r")" "$(( (r >> 24) & 0xFF ))"
	fi
	if [ -d "$R/sys/class/ubi/ubi0_3" ] && [ -d "$R/sys/class/ubi/ubi0_4" ]; then
		echo "UBI: $(ubi avail_eraseblocks) free LEBs of $(ubi eraseblock_size) B"
		for n in 3 4; do
			echo "vol $n: $(v $n name) $(v $n type) $(v $n reserved_ebs) LEBs, $(v $n data_bytes) B data, corrupted=$(v $n corrupted) upd_marker=$(v $n upd_marker)"
		done
		if [ "$(head -c 4 "$R/dev/ubi0_4" 2>/dev/null || true)" = hsqs ]; then
			echo "vol 4 holds a squashfs"
		else
			echo "vol 4 does not start with a squashfs"
		fi
	else
		echo "UBI vol 3/4: not visible from this system"
	fi
	for f in $(markers); do echo "WARNING: $f exists (a lab trial marker; remove it before booting mainline)"; done
	return 0
}

cmd_flash() {
	CHECK=0
	if [ "${1:-}" = --check ]; then CHECK=1; shift; fi
	{ [ $# -ge 4 ] && [ $# -le 5 ]; } || usage
	RFS=$1 RSHA=$2 ITB=$3 ISHA=$4 V4=${5:-265}
	case "$V4" in '' | *[!0-9]*) die "VOL4_LEBS '$V4' is not a number" ;; esac
	need_stock_slot2
	[ -f "$RFS" ] || die "$RFS: no such file"
	[ -f "$ITB" ] || die "$ITB: no such file"
	{ [ "$(v 3 name)" = bootfs1 ] && [ "$(v 4 name)" = rootfs1 ]; } || die "vol 3/4 are not bootfs1/rootfs1"
	for n in 3 4; do
		[ ! -e "$R/dev/ubiblock0_$n" ] || die "vol $n is in use (/dev/ubiblock0_$n exists)"
		! grep -qE "ubi0_$n |ubi0:$(v $n name) |ubiblock0_$n " "$R/proc/mounts" || die "vol $n is mounted"
	done
	LEB=$(ubi eraseblock_size)
	[ "$LEB" = $LEB_GTBE98 ] || die "LEB size $LEB B, expected $LEB_GTBE98 B: not the GT-BE98 NAND layout"
	say "checking the sha256 of the inputs"
	[ "$(sha256sum "$RFS" | cut -d' ' -f1)" = "$RSHA" ] || die "$RFS: sha256 mismatch (want $RSHA)"
	[ "$(sha256sum "$ITB" | cut -d' ' -f1)" = "$ISHA" ] || die "$ITB: sha256 mismatch (want $ISHA)"
	[ "$(head -c 4 "$RFS")" = hsqs ] || die "$RFS is not a squashfs (U-Boot checks vol 4's magic)"
	if which hexdump >/dev/null 2>&1; then
		fdt=$(head -c 4 "$ITB" | hexdump -v -e '1/1 "%02x"')
		[ "$fdt" = d00dfeed ] || die "$ITB is not a FIT image (magic $fdt)"
	fi
	rsize=$(wc -c < "$RFS"); isize=$(wc -c < "$ITB")
	rneed=$(( (rsize + LEB - 1) / LEB )); ineed=$(( (isize + LEB - 1) / LEB ))
	[ "$V4" -ge "$rneed" ] || die "VOL4_LEBS $V4 < the $rneed LEBs the rootfs needs"
	avail=$(ubi avail_eraseblocks)
	v4now=$(v 4 reserved_ebs); v3now=$(v 3 reserved_ebs)
	d4=0; [ "$V4" -le "$v4now" ] || d4=$((V4 - v4now))
	d3=0; [ "$ineed" -le "$v3now" ] || d3=$((ineed - v3now))
	say "UBI: $avail free LEBs; vol 3 bootfs1 $v3now LEBs (FIT needs $ineed), vol 4 rootfs1 $v4now LEBs (rootfs needs $rneed, target $V4)"
	say "plan: vol 4 $v4now -> $V4 LEBs, vol 3 +$d3 LEBs, then write vol 4, then vol 3"
	[ $((d4 + d3)) -le "$avail" ] || die "not enough free LEBs ($((d4 + d3)) needed, $avail free)"
	if [ $CHECK = 1 ]; then say "check only: nothing written"; exit 0; fi

	[ "$V4" -eq "$v4now" ] || "$(t ubirsvol)" "$R/dev/ubi0" -n 4 -S "$V4"
	"$(t ubiupdatevol)" "$R/dev/ubi0_4" "$RFS"
	got=$(head -c "$rsize" "$R/dev/ubi0_4" | sha256sum | cut -d' ' -f1)
	[ "$got" = "$RSHA" ] || die "vol 4 read back: sha256 $got (want $RSHA); do NOT boot slot 1, flash again"
	say "vol 4 rootfs1: $rsize B written, read back OK"
	[ $d3 = 0 ] || "$(t ubirsvol)" "$R/dev/ubi0" -n 3 -S "$ineed"
	"$(t ubiupdatevol)" "$R/dev/ubi0_3" "$ITB"
	got=$(head -c "$isize" "$R/dev/ubi0_3" | sha256sum | cut -d' ' -f1)
	[ "$got" = "$ISHA" ] || die "vol 3 read back: sha256 $got (want $ISHA); do NOT boot slot 1, flash again"
	say "vol 3 bootfs1: $isize B written, read back OK"
	sync
	say "FLASH-OK: free LEBs now $(ubi avail_eraseblocks); boot it once with: $0 boot"
}

cmd_boot() {
	CHECK=0 CLEAR=0 REBOOT=1
	for a in "$@"; do
		case "$a" in
		--check) CHECK=1 ;;
		--clear-postcode) CLEAR=1 ;;
		--no-reboot) REBOOT=0 ;;
		*) usage ;;
		esac
	done
	need_stock_slot2
	[ "$(head -c 4 "$R/dev/ubi0_4" 2>/dev/null || true)" = hsqs ] || die "vol 4 does not hold a squashfs: flash first"
	m=$(markers)
	[ -z "$m" ] || die "$m exists: a lab trial marker that the stock firmware reacts to; remove it first"
	rr=$(rreason)
	case "$rr" in
	34) ;;
	1) die "reset_reason is already 1: a one-shot boot of slot 1 is already armed; the next reboot starts it" ;;
	*) die "reset_reason is '$rr', expected 34 (normal): after a power-on, reboot the stock firmware once and retry" ;;
	esac
	if [ $CHECK = 1 ]; then say "check only: preconditions OK, nothing armed"; exit 0; fi
	if [ $CLEAR = 1 ]; then
		r=$(devmem $BSR 32) || die "devmem read of $BSR failed"
		devmem $BSR 32 "$(hex32 "$(( r & 0x00FFFFFF ))")"
		r2=$(devmem $BSR 32)
		[ $(( r2 & 0x00FFFFFF )) = $(( r & 0x00FFFFFF )) ] ||
			die "boot-state register bits [23:0] changed ($(hex32 "$r") -> $(hex32 "$r2")): STOP, do not reboot; power-cycle the box"
		say "post-code byte cleared ($(hex32 "$r") -> $(hex32 "$r2"))"
	fi
	bcm_bootstate 3 >/dev/null 2>&1 || true
	rr=$(rreason)
	[ "$rr" = 1 ] || die "bcm_bootstate 3 did not arm the one-shot boot (reset_reason '$rr', want 1); not rebooting"
	sync
	if [ $REBOOT = 0 ]; then
		say "BOOT-ARMED: one-shot boot of slot 1 armed; reboot to start it"
	elif [ -n "$R" ]; then
		say "BOOT-ARMED: (test root: not rebooting)"
	else
		say "BOOT-ARMED: one-shot boot of slot 1 armed; rebooting (any later reset returns to stock)"
		reboot
	fi
}

[ $# -ge 1 ] || usage
cmd=$1; shift
case "$cmd" in
status) cmd_status ;;
flash) cmd_flash "$@" ;;
boot) cmd_boot "$@" ;;
*) usage ;;
esac

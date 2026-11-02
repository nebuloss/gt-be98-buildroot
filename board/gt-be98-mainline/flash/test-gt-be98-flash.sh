#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# test-gt-be98-flash.sh - host-side test of gt-be98-flash.sh against a fake
# stock system (GT_BE98_FLASH_ROOT: /proc, /sys/class/ubi, /dev/ubi0_N files;
# fake bcm_bootstate, devmem, ubirsvol, ubiupdatevol first in PATH). Every
# refusal case has its accepted twin, so a script that refuses everything (or
# nothing) fails. No device, no root, nothing outside a temp directory.
#
#   SH="busybox sh" sh board/gt-be98-mainline/flash/test-gt-be98-flash.sh
#
# SH: the shell that runs gt-be98-flash.sh (default sh; the box runs busybox
# ash). Prints one line per case and "FLASH-TEST: PASS n/n" at the end.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SH=${SH:-sh}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
LEB=126976

# ---- fake tools ------------------------------------------------------------------
B=$T/bin
mkdir -p "$B"
cat > "$B/bcm_bootstate" <<'EOF'
#!/bin/sh
F=$GT_BE98_FLASH_ROOT
if [ $# = 0 ]; then
	echo "committed $(cat "$F/committed") valid 1,2 seq 50,51"
	exit 0
fi
[ "$1" = 3 ] && [ ! -e "$F/bootstate-noop" ] && echo 1 > "$F/proc/bootstate/reset_reason"
exit 0
EOF
cat > "$B/devmem" <<'EOF'
#!/bin/sh
F=$GT_BE98_FLASH_ROOT
[ "$1" = 0xff802628 ] || { echo "devmem: unexpected address $1" >&2; exit 1; }
if [ $# -ge 3 ]; then
	if [ -e "$F/devmem-corrupt" ]; then
		printf '0x%08X\n' $(( $3 ^ 1 )) > "$F/bsr"
	else
		printf '0x%08X\n' $(( $3 )) > "$F/bsr"
	fi
	echo "$3" >> "$F/devmem-writes"
else
	cat "$F/bsr"
fi
EOF
cat > "$B/ubirsvol" <<'EOF'
#!/bin/sh
F=$GT_BE98_FLASH_ROOT
[ "$1" = "$F/dev/ubi0" ] && [ "$2" = -n ] && [ "$4" = -S ] || { echo "ubirsvol: bad args $*" >&2; exit 1; }
v=$F/sys/class/ubi/ubi0_$3
old=$(cat "$v/reserved_ebs"); a=$(cat "$F/sys/class/ubi/ubi0/avail_eraseblocks")
echo $(( a - ($5 - old) )) > "$F/sys/class/ubi/ubi0/avail_eraseblocks"
echo "$5" > "$v/reserved_ebs"
echo "ubirsvol $3 $5" >> "$F/writes"
EOF
cat > "$B/ubiupdatevol" <<'EOF'
#!/bin/sh
F=$GT_BE98_FLASH_ROOT
case "$1" in "$F"/dev/ubi0_[34]) ;; *) echo "ubiupdatevol: bad volume $1" >&2; exit 1 ;; esac
cp "$2" "$1"
[ -e "$F/vol-corrupt" ] && printf X | dd of="$1" bs=1 seek=100 conv=notrunc 2>/dev/null
n=${1##*_}
wc -c < "$2" > "$F/sys/class/ubi/ubi0_$n/data_bytes"
echo "ubiupdatevol $n" >> "$F/writes"
EOF
chmod +x "$B"/*

# ---- inputs ----------------------------------------------------------------------
I=$T/in
mkdir -p "$I"
{ printf hsqs; head -c 400000 /dev/urandom; } > "$I/rootfs.squashfs"
{ printf '\320\015\376\355'; head -c 300000 /dev/urandom; } > "$I/ml-bootfs.itb"
{ printf xxxx; head -c 1000 /dev/urandom; } > "$I/not-squashfs"
RSHA=$(sha256sum "$I/rootfs.squashfs" | cut -d' ' -f1)
ISHA=$(sha256sum "$I/ml-bootfs.itb" | cut -d' ' -f1)
NSHA=$(sha256sum "$I/not-squashfs" | cut -d' ' -f1)

# a fresh fake stock system: slot 2 booted + committed, reset reason 34
mkroot() {
	F=$T/root
	rm -rf "$F"
	mkdir -p "$F/proc/bootstate" "$F/dev" "$F/data" "$F/sys/class/ubi/ubi0"
	echo "console=ttyAMA0 ubi.block=0,6 root=/dev/ubiblock0_6" > "$F/proc/cmdline"
	echo "/dev/ubiblock0_6 / squashfs ro 0 0" > "$F/proc/mounts"
	echo 34 > "$F/proc/bootstate/reset_reason"
	echo 2 > "$F/committed"
	echo 0xFB210034 > "$F/bsr"
	echo 306 > "$F/sys/class/ubi/ubi0/avail_eraseblocks"
	echo $LEB > "$F/sys/class/ubi/ubi0/eraseblock_size"
	for n in 3 4; do
		d=$F/sys/class/ubi/ubi0_$n
		mkdir -p "$d"
		echo 0 > "$d/corrupted"; echo 0 > "$d/upd_marker"
	done
	echo bootfs1 > "$F/sys/class/ubi/ubi0_3/name"; echo static > "$F/sys/class/ubi/ubi0_3/type"
	echo 397 > "$F/sys/class/ubi/ubi0_3/reserved_ebs"; echo 0 > "$F/sys/class/ubi/ubi0_3/data_bytes"
	echo rootfs1 > "$F/sys/class/ubi/ubi0_4/name"; echo dynamic > "$F/sys/class/ubi/ubi0_4/type"
	echo 9 > "$F/sys/class/ubi/ubi0_4/reserved_ebs"; echo 4096 > "$F/sys/class/ubi/ubi0_4/data_bytes"
	head -c 4096 /dev/zero > "$F/dev/ubi0_3"
	head -c 4096 /dev/zero > "$F/dev/ubi0_4"
	: > "$F/writes"
}

pass=0 fail=0
# run NAME WANT_RC WANT_TEXT -- args...   (output must contain WANT_TEXT)
run() {
	name=$1 want=$2 text=$3; shift 4
	out=$(GT_BE98_FLASH_ROOT=$F PATH="$B:$PATH" $SH "$HERE/gt-be98-flash.sh" "$@" 2>&1); rc=$?
	if [ "$rc" = "$want" ] && printf '%s\n' "$out" | grep -qF -- "$text"; then
		echo "ok   $name (rc $rc)"; pass=$((pass + 1)); return 0
	fi
	echo "FAIL $name: rc $rc (want $want), want text '$text'; output:"
	printf '%s\n' "$out" | sed 's/^/     | /'
	fail=$((fail + 1)); return 1
}
# check NAME CONDITION...: an extra assertion about the fake system afterwards
check() {
	name=$1; shift
	if "$@"; then echo "ok   $name"; pass=$((pass + 1)); else echo "FAIL $name"; fail=$((fail + 1)); fi
}
nowrites() { [ ! -s "$F/writes" ]; }
rr_is() { [ "$(cat "$F/proc/bootstate/reset_reason")" = "$1" ]; }
FL="$I/rootfs.squashfs $RSHA $I/ml-bootfs.itb $ISHA"

# ---- status ------------------------------------------------------------------------
mkroot; run status-stock 0 "booted slot 2" -- status
mkroot; echo "console=ttyAMA0" > "$F/proc/cmdline"; run status-not-stock 0 "not the stock firmware" -- status

# ---- flash: accepted -----------------------------------------------------------------
mkroot; run flash-check-ok 0 "check only: nothing written" -- flash --check $FL
check flash-check-wrote-nothing nowrites
mkroot; run flash-ok 0 "FLASH-OK" -- flash $FL
check flash-vol4-content [ "$(head -c "$(wc -c < "$I/rootfs.squashfs")" "$F/dev/ubi0_4" | sha256sum | cut -d' ' -f1)" = "$RSHA" ]
check flash-vol3-content [ "$(sha256sum < "$F/dev/ubi0_3" | cut -d' ' -f1)" = "$ISHA" ]
check flash-vol4-resized [ "$(cat "$F/sys/class/ubi/ubi0_4/reserved_ebs")" = 265 ]
check flash-order [ "$(tr '\n' ' ' < "$F/writes")" = "ubirsvol 4 265 ubiupdatevol 4 ubiupdatevol 3 " ]
check flash-no-arm rr_is 34
mkroot; echo 265 > "$F/sys/class/ubi/ubi0_4/reserved_ebs"; run flash-ok-no-resize 0 "FLASH-OK" -- flash $FL
check flash-no-resize-order [ "$(tr '\n' ' ' < "$F/writes")" = "ubiupdatevol 4 ubiupdatevol 3 " ]
mkroot; echo 2 > "$F/sys/class/ubi/ubi0_3/reserved_ebs"; run flash-grows-vol3 0 "FLASH-OK" -- flash $FL
check flash-vol3-grown [ "$(cat "$F/sys/class/ubi/ubi0_3/reserved_ebs")" = 3 ]

# ---- flash: refused (nothing written) --------------------------------------------------
mkroot; run flash-bad-rootfs-sha 1 "sha256 mismatch" -- flash "$I/rootfs.squashfs" "$ISHA" "$I/ml-bootfs.itb" "$ISHA"
check flash-bad-sha-wrote-nothing nowrites
mkroot; run flash-bad-itb-sha 1 "sha256 mismatch" -- flash "$I/rootfs.squashfs" "$RSHA" "$I/ml-bootfs.itb" "$RSHA"
mkroot; run flash-not-squashfs 1 "is not a squashfs" -- flash "$I/not-squashfs" "$NSHA" "$I/ml-bootfs.itb" "$ISHA"
mkroot; run flash-not-fit 1 "is not a FIT image" -- flash "$I/rootfs.squashfs" "$RSHA" "$I/rootfs.squashfs" "$RSHA"
mkroot; echo "console=ttyAMA0 ubi.block=0,4" > "$F/proc/cmdline"; run flash-booted-slot1 1 "running from slot 1" -- flash $FL
check flash-slot1-wrote-nothing nowrites
mkroot; echo 1 > "$F/committed"; run flash-committed-1 1 "committed slot is '1'" -- flash $FL
mkroot; echo "console=ttyAMA0 root=/dev/sda" > "$F/proc/cmdline"; run flash-not-stock 1 "not the stock firmware" -- flash $FL
mkroot; : > "$F/dev/ubiblock0_4"; run flash-vol4-in-use 1 "vol 4 is in use" -- flash $FL
mkroot; echo "ubi0:rootfs1 /mnt ubifs ro 0 0" >> "$F/proc/mounts"; run flash-vol4-mounted 1 "vol 4 is mounted" -- flash $FL
mkroot; echo rootfs2 > "$F/sys/class/ubi/ubi0_4/name"; run flash-wrong-names 1 "are not bootfs1/rootfs1" -- flash $FL
mkroot; echo 100 > "$F/sys/class/ubi/ubi0/avail_eraseblocks"; run flash-no-space 1 "not enough free LEBs" -- flash $FL
check flash-no-space-wrote-nothing nowrites
mkroot; echo 131072 > "$F/sys/class/ubi/ubi0/eraseblock_size"; run flash-wrong-leb 1 "LEB size 131072" -- flash $FL
mkroot; run flash-vol4-too-small 1 "VOL4_LEBS 2 <" -- flash $FL 2
mkroot; run flash-usage 2 "flash --check" -- flash "$I/rootfs.squashfs" "$RSHA"
mkroot; : > "$F/vol-corrupt"; run flash-readback-mismatch 1 "vol 4 read back" -- flash $FL

# ---- boot: accepted ------------------------------------------------------------------------
mkroot; GT_BE98_FLASH_ROOT=$F PATH="$B:$PATH" $SH "$HERE/gt-be98-flash.sh" flash $FL > /dev/null 2>&1
cp -a "$F" "$T/flashed"
reflashed() { rm -rf "$F"; cp -a "$T/flashed" "$F"; }
reflashed; run boot-check-ok 0 "preconditions OK" -- boot --check
check boot-check-no-arm rr_is 34
reflashed; run boot-ok 0 "BOOT-ARMED" -- boot
check boot-armed rr_is 1
check boot-no-register-write [ ! -e "$F/devmem-writes" ]
reflashed; run boot-clear-postcode 0 "post-code byte cleared (0xFB210034 -> 0x00210034)" -- boot --clear-postcode
check boot-clear-armed rr_is 1

# ---- boot: refused (not armed) ----------------------------------------------------------------
mkroot; run boot-not-flashed 1 "flash first" -- boot
check boot-not-flashed-no-arm rr_is 34
reflashed; echo ffffffff > "$F/proc/bootstate/reset_reason"; run boot-after-power-on 1 "expected 34" -- boot
reflashed; echo 1 > "$F/proc/bootstate/reset_reason"; run boot-already-armed 1 "already armed" -- boot
reflashed; : > "$F/data/open_enet"; run boot-lab-marker 1 "/data/open_enet exists" -- boot
check boot-marker-no-arm rr_is 34
reflashed; echo "console=ttyAMA0 ubi.block=0,4" > "$F/proc/cmdline"; run boot-booted-slot1 1 "running from slot 1" -- boot
reflashed; echo 1 > "$F/committed"; run boot-committed-1 1 "committed slot is '1'" -- boot
reflashed; : > "$F/bootstate-noop"; run boot-arm-not-taken 1 "did not arm" -- boot
reflashed; : > "$F/devmem-corrupt"; run boot-register-guard 1 "bits [23:0] changed" -- boot --clear-postcode
check boot-register-guard-no-arm rr_is 34
reflashed; run boot-usage 2 "boot [--check]" -- boot --bogus

echo "FLASH-TEST: $([ $fail = 0 ] && echo PASS || echo FAIL) $pass/$((pass + fail)) (shell: $SH)"
[ $fail = 0 ]

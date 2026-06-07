#!/bin/bash
# From-source rootfs variant assembly + parity (build-only, no flash, no device).
#
# Builds a rootfs that is the br-0049 baseline with its proprietary userspace
# CORE replaced by the from-source Buildroot recipes (gt-be98-libshared /
# -nvram / -hostapd, built into the gt-be98_fromsrc_defconfig target dir):
#   libshared.so  -> from source (ABI-perfect, byte-identical when stripped)
#   hostapd       -> from source (DRIVER_BRCM daemon, byte-identical stripped)
#   hostapd_cli   -> from source (byte-identical stripped)
#   libnvram.so   -> clean-room open NETLINK_WLCSM client (functional, not byte)
#   nvram         -> clean-room open CLI                  (functional, not byte)
# Everything else (the irreducible Broadcom graft + open/upstream packages) is
# carried over byte-for-byte from the baseline.
#
# Usage: fromsrc-assemble.sh <baseline-rootfs.img> <br-target-dir> <out-dir>
set -euo pipefail
BASE_IMG="${1:?baseline rootfs.img}"; BRT="${2:?O=.../target}"; OUT="${3:?out dir}"
UNSQ="${UNSQ:-/home/guillaume/be98/buildroot/output/host/bin/unsquashfs}"
MKSQ="${MKSQ:-/home/guillaume/be98/buildroot/output/host/bin/mksquashfs}"
FW="${FW:-/home/guillaume/be98/gt-be98-firmware}"
SDK="$FW/vendor/asuswrt-merlin.ng/release/src-rt-5.04behnd.4916"
TC="$FW/toolchain/am-toolchains/brcm-arm-hnd"
STRIP="$(find "$TC" -path '*gcc-10.3*' -name 'arm-buildroot-linux-gnueabi-strip' | head -1)"
HA="$SDK/bcmdrivers/broadcom/net/wl/impl103/main/components/opensource/router_tools/hostapd/hostapd"

mkdir -p "$OUT"; BASE="$OUT/baseline"; FS="$OUT/fromsrc"
rm -rf "$BASE" "$FS"
"$UNSQ" -d "$BASE" "$BASE_IMG" >/dev/null
cp -a "$BASE" "$FS"

ins(){ cp "$1" "$2"; "$STRIP" "$2"; }            # install stripped (device packaging)
ins "$BRT/usr/lib/libshared.so" "$FS/usr/lib/libshared.so"
ins "$HA/hostapd"               "$FS/usr/sbin/hostapd"
ins "$HA/hostapd_cli"           "$FS/usr/sbin/hostapd_cli"
ins "$BRT/usr/lib/libnvram.so"  "$FS/lib/libnvram.so"
ins "$BRT/bin/nvram"            "$FS/bin/nvram"

echo "== PARITY vs baseline (br-0049) =="
diff -rq "$BASE" "$FS" 2>/dev/null | sed 's#'"$OUT"'/##g' || true
echo "  differing files: $(diff -rq "$BASE" "$FS" 2>/dev/null | grep -c differ)"

SQ="$OUT/fromsrc-rootfs.squashfs"; rm -f "$SQ"
"$MKSQ" "$FS" "$SQ" -noappend -all-root -comp xz -b 131072 -no-progress >/dev/null
echo "== from-source rootfs: $(stat -c%s "$SQ") bytes  sha=$(sha256sum "$SQ" | cut -d' ' -f1) =="
exit 0

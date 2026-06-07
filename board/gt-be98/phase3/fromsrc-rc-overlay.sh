#!/bin/bash
# From-source rc OVERLAY assembly + image-diff gate + FIT package
# (build-only; NO flash, NO device).
#
# Produces a flashable rootfs that is the br-0049 baseline with ONLY /sbin/rc
# replaced by the from-source build (package/gt-be98-rc -> build-rc.sh, which
# links rc via the merlin SDK build-glue). EVERYTHING ELSE - including the stock
# /lib/libnvram.so blob and the from-source-byte-identical libshared - is carried
# over byte-for-byte from br-0049. This proves OUR-built rc boots without
# perturbing any other userspace component.
#
# rc provenance (verified 2026-06-07):
#   from-source rc (SDK router/rc/rc, build-rc.sh output) = ELF32 ARM EABI5
#   soft-float, NOT stripped, sha 8d61550e..., 5881632 B. STRIPPED with the
#   gcc-10.3 cross strip it is BYTE-IDENTICAL to the br-0049 stock blob rc
#   (768e18a5..., 2666744 B) => reproducible build. We overlay the UNSTRIPPED
#   binary so the artifact is unmistakably ours and the flash trial is a genuine
#   distinct-binary boot test (image-diff then shows /sbin/rc as the sole diff).
#   The stripped form would yield a content-byte-identical image (also valid,
#   smaller) - set RC_STRIP=1 to overlay the stripped rc instead.
#
# GATE (the bar): no-dereference structural manifest diff + content-hash diff of
# every regular file MUST show ONLY ./sbin/rc differing, and /lib/libnvram.so
# MUST equal the br-0049 stock blob (NOT the clean-room boot-breaker 2e95cb80).
# Fails closed (no package) on any other diff.
#
# Usage: fromsrc-rc-overlay.sh <br-0049.pkgtb> <out-dir>
set -euo pipefail
BR0049_PKGTB="${1:?br-0049 .pkgtb}"; OUT="${2:?out dir}"
FW="${FW:-/home/guillaume/be98/gt-be98-firmware}"
SDK="$FW/vendor/asuswrt-merlin.ng/release/src-rt-5.04behnd.4916"
TC="$FW/toolchain/am-toolchains/brcm-arm-hnd"
UNSQ="${UNSQ:-/home/guillaume/be98/buildroot/output/host/bin/unsquashfs}"
MKSQ="${MKSQ:-/home/guillaume/be98/buildroot/output/host/bin/mksquashfs}"
FAKEROOT="${FAKEROOT:-/home/guillaume/be98/buildroot/output/host/bin/fakeroot}"
DUMPIMAGE="${DUMPIMAGE:-/usr/bin/dumpimage}"
STRIP="$(find "$TC" -path '*arm_softfp*gcc-10.3*' -name 'arm-buildroot-linux-gnueabi-strip' | head -1)"
FROMSRC_RC="${FROMSRC_RC:-$SDK/router/rc/rc}"        # build-rc.sh output (unstripped)
CEILING="${CEILING:-71106560}"                       # slot-2 rootfs ceiling (bytes)
RC_STRIP="${RC_STRIP:-0}"

mkdir -p "$OUT"/{extract,base,asm,verify,images,pkg}

# 1. Extract br-0049 (bootfs stays UNCHANGED; only rootfs is rebuilt).
"$DUMPIMAGE" -T flat_dt -p 0 -o "$OUT/extract/bootfs.itb"       "$BR0049_PKGTB" >/dev/null
"$DUMPIMAGE" -T flat_dt -p 1 -o "$OUT/extract/rootfs.squashfs"  "$BR0049_PKGTB" >/dev/null
rm -rf "$OUT/base"; "$FAKEROOT" -s "$OUT/base.fr" -- "$UNSQ" -d "$OUT/base" -no-progress "$OUT/extract/rootfs.squashfs" >/dev/null

# 2. Overlay ONLY /sbin/rc (mode 0500, as package/gt-be98-rc installs it).
rm -rf "$OUT/asm"; cp -a "$OUT/base" "$OUT/asm"
install -m 0700 "$FROMSRC_RC" "$OUT/asm/sbin/rc"   # install overwrites the 0500 stock rc
[ "$RC_STRIP" = 1 ] && "$STRIP" "$OUT/asm/sbin/rc"
chmod 0500 "$OUT/asm/sbin/rc"

# 3. Re-squash merlin-exact (xz / 131072 / all-root / NFS-exportable / no xattrs).
SQ="$OUT/images/rootfs.squashfs"; rm -f "$SQ"
"$MKSQ" "$OUT/asm" "$SQ" -noappend -all-root -comp xz -b 131072 -no-progress >/dev/null

# 4. GATE: re-extract and diff (no-dereference) vs pristine br-0049.
rm -rf "$OUT/verify"; "$FAKEROOT" -s "$OUT/verify.fr" -- "$UNSQ" -d "$OUT/verify" -no-progress "$SQ" >/dev/null
man(){ ( cd "$1"; find . -mindepth 1 \( -type f -o -type l -o -type d \) -printf '%y\t%m\t%p\t' -a \
        \( -type l -printf '->%l\n' -o -type d -printf '\n' -o -type f -printf '%s\n' \) | LC_ALL=C sort -t$'\t' -k3 ); }
hsh(){ ( cd "$1"; find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum ); }
man "$OUT/base" > "$OUT/manifest.base"; man "$OUT/verify" > "$OUT/manifest.verify"
hsh "$OUT/base" > "$OUT/hashes.base";   hsh "$OUT/verify" > "$OUT/hashes.verify"
SDIFF="$(diff "$OUT/manifest.base" "$OUT/manifest.verify" | grep -E '^[<>]' | grep -v $'\t./sbin/rc\t' || true)"
CDIFF="$(diff "$OUT/hashes.base"   "$OUT/hashes.verify"   | grep -E '^[<>]' | grep -v '  ./sbin/rc$'  || true)"
LIBNV_BASE="$(sha256sum "$OUT/base/lib/libnvram.so"   | cut -d' ' -f1)"
LIBNV_VER="$(sha256sum  "$OUT/verify/lib/libnvram.so" | cut -d' ' -f1)"
echo "== GATE =="
echo "  rc stock : $(sha256sum "$OUT/base/sbin/rc"   | cut -d' ' -f1)"
echo "  rc built : $(sha256sum "$OUT/verify/sbin/rc" | cut -d' ' -f1)"
echo "  libnvram : base=$LIBNV_BASE verify=$LIBNV_VER"
if [ -n "$SDIFF$CDIFF" ] || [ "$LIBNV_BASE" != "$LIBNV_VER" ] || [ "${LIBNV_VER:0:8}" = "2e95cb80" ]; then
    echo "  VERDICT: FAIL - unexpected diff (NOT packaging):"; printf '%s\n%s\n' "$SDIFF" "$CDIFF"; exit 2
fi
echo "  VERDICT: PASS - only /sbin/rc differs; libnvram = br-0049 stock blob"

# 5. Size ceiling + FIT package (bootfs from br-0049, UNCHANGED).
SZ="$(stat -c%s "$SQ")"
[ "$SZ" -lt "$CEILING" ] || { echo "FAIL: rootfs $SZ >= ceiling $CEILING"; exit 3; }
echo "  rootfs $SZ B < ceiling $CEILING B (headroom $((CEILING-SZ)) B)"
GT_BE98_BOOTFS_ITB="$OUT/extract/bootfs.itb" \
GT_BE98_MKIMAGE="${GT_BE98_MKIMAGE:-$SDK/bootloaders/obj/uboot/tools/mkimage}" \
BR2_EXTERNAL_GT_BE98_PATH="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)" \
    bash "$(dirname -- "$0")/../post-image.sh" "$OUT/images"
mv "$OUT/images/GT-BE98_nand_squashfs.pkgtb" "$OUT/pkg/GT-BE98_fromsrc-rc_nand_squashfs.pkgtb"
echo "== pkgtb: $OUT/pkg/GT-BE98_fromsrc-rc_nand_squashfs.pkgtb  sha=$(sha256sum "$OUT/pkg/GT-BE98_fromsrc-rc_nand_squashfs.pkgtb" | cut -d' ' -f1) =="
exit 0

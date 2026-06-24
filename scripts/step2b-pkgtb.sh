#!/usr/bin/env bash
# step2b-pkgtb.sh — build a GT-BE98 .pkgtb whose bootfs/kernel is built FROM
# SOURCE (Step 2b), instead of the prebuilt gt-be98-bootfs blob (Step 2a).
#
# Buildroot builds the userspace/rootfs from source (external gt-be98-toolchain),
# and post-image.sh wraps it around a FROM-SOURCE bootfs FIT via the
# GT_BE98_BOOTFS_ITB override — with the prebuilt gt-be98-bootfs package disabled.
#
# PREREQUISITE — the from-source bootfs FIT (ATF + U-Boot + aarch64 kernel + DTBs).
# Produce it from gt-be98-kernel against the external toolchain:
#     TC_FROM_RELEASE=1 ./scripts/build-kernel.sh full
#   -> <merlin-sdk>/targets/96813GW/bcm96813GW_uboot_linux.itb
# (build-kernel.sh `full` is currently the reliable FIT assembler; a lightweight
#  kernel->FIT-only target is a TODO: standalone merlin `image_linux` doesn't wrap
#  the FIT without the full IMAGE_GOAL/BCM_FLASH_LAYOUTS context.)
#
# Verified: the resulting .pkgtb's embedded bootfs sub-image sha equals the
# from-source bootfs (NOT the validated-0031 prebuilt) — the kernel is from source.
#
# Usage:
#   scripts/step2b-pkgtb.sh <bootfs.itb>
# Env:
#   BUILDROOT  upstream Buildroot dir   (default ~/be98/buildroot)
#   O          Buildroot output dir     (default ~/be98/bm-step2b)
set -euo pipefail

EXT="$(cd "$(dirname "$0")/.." && pwd)"          # this BR2_EXTERNAL tree
BOOTFS_ITB="${1:?usage: step2b-pkgtb.sh <bootfs.itb>}"
[[ -f "$BOOTFS_ITB" ]] || { echo "ERROR: bootfs .itb not found: $BOOTFS_ITB" >&2; exit 1; }
BOOTFS_ITB="$(cd "$(dirname "$BOOTFS_ITB")" && pwd)/$(basename "$BOOTFS_ITB")"   # absolute
BUILDROOT="${BUILDROOT:-$HOME/be98/buildroot}"
O="${O:-$HOME/be98/bm-step2b}"

echo "step2b: BR2_EXTERNAL=$EXT"
echo "step2b: from-source bootfs=$BOOTFS_ITB"
echo "step2b: buildroot=$BUILDROOT  O=$O"

make -C "$BUILDROOT" BR2_EXTERNAL="$EXT" O="$O" gt-be98_defconfig
# Step 2b: drop the prebuilt bootfs blob; we supply a from-source one.
sed -i -E 's/^BR2_PACKAGE_GT_BE98_BOOTFS=y/# &/' "$O/.config"
make -C "$BUILDROOT" O="$O" olddefconfig
GT_BE98_BOOTFS_ITB="$BOOTFS_ITB" make -C "$BUILDROOT" O="$O" -j"$(nproc)"

PKGTB="$O/images/GT-BE98_nand_squashfs.pkgtb"
echo "step2b: done -> $PKGTB"
if command -v dumpimage >/dev/null 2>&1 || [[ -x "$O/host/bin/dumpimage" ]]; then
    DI="$(command -v dumpimage || echo "$O/host/bin/dumpimage")"
    "$DI" -T flat_dt -p 0 -o /tmp/step2b-bootfs.itb "$PKGTB" 2>/dev/null || true
    echo "step2b: pkgtb bootfs sha = $(sha256sum /tmp/step2b-bootfs.itb 2>/dev/null | cut -d' ' -f1)"
    echo "step2b: source bootfs sha = $(sha256sum "$BOOTFS_ITB" | cut -d' ' -f1)  (should match)"
fi

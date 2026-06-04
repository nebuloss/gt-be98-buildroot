#!/bin/sh
# Post-image step 1 for the "full firmware" build (runs before post-image.sh).
# Replaces Buildroot's throwaway rootfs.squashfs with merlin's FINAL rootfs.img
# (provided byte-for-byte by the gt-be98-rootfs package), so the assembled .pkgtb
# is content-identical to a working merlin build. $1 = BINARIES_DIR.
#
# Why not assemble from source: the rootfs is the full proprietary ASUS userspace
# AFTER merlin's buildFS post-processing (lib flattening, mount dirs, dev nodes);
# reusing the built image guarantees parity. Customize via /jffs + nvram instead.
set -e
BINARIES_DIR="$1"
: "${BINARIES_DIR:?post-image-full.sh: BINARIES_DIR not given}"
: "${BUILD_DIR:?post-image-full.sh: BUILD_DIR not set}"

IMG="$(find "$BUILD_DIR" -name 'rootfs.img' -path '*gt-be98-rootfs*' | head -1)"
[ -n "$IMG" ] || { echo "post-image-full: rootfs.img not found (enable BR2_PACKAGE_GT_BE98_ROOTFS)"; exit 1; }

cp -f "$IMG" "$BINARIES_DIR/rootfs.squashfs"
echo "post-image-full: rootfs.squashfs = merlin rootfs.img ($(du -h "$IMG" | cut -f1), content-identical to a working merlin build)"

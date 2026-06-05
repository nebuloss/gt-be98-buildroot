#!/bin/sh
# Post-image step 1 for the "full firmware" build (runs before post-image.sh).
# Produces $BINARIES_DIR/rootfs.squashfs from the gt-be98-rootfs package's
# rootfs.img (the validated ASUS rootfs blob). $1 = BINARIES_DIR.
#
# Two modes:
#  - VERBATIM (no transform inputs): byte-for-byte copy of the blob, so the
#    assembled .pkgtb is content-identical to the validated merlin build (M1).
#  - MUTATED (M3+): board/gt-be98/rootfs-transform.sh unpacks the blob,
#    applies rootfs-overlay-full/ + rootfs-remove.list + the generated
#    /rom/etc/gt-be98-release marker, and re-squashes with merlin's exact
#    mksquashfs options. Triggered automatically when the overlay dir has
#    content or the removal list exists; force-disable with GT_BE98_VERBATIM=1.
#
# Why blob, not source: the rootfs is the full proprietary ASUS userspace
# AFTER merlin's buildFS post-processing (lib flattening, mount dirs, dev
# nodes); reusing the built image guarantees parity.
set -e
BINARIES_DIR="$1"
: "${BINARIES_DIR:?post-image-full.sh: BINARIES_DIR not given}"
: "${BUILD_DIR:?post-image-full.sh: BUILD_DIR not set}"

BOARD="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

IMG="$(find "$BUILD_DIR" -name 'rootfs.img' -path '*gt-be98-rootfs*' | head -1)"
[ -n "$IMG" ] || { echo "post-image-full: rootfs.img not found (enable BR2_PACKAGE_GT_BE98_ROOTFS)"; exit 1; }

WANT_TRANSFORM=0
if [ "${GT_BE98_VERBATIM:-0}" != "1" ]; then
    [ -f "$BOARD/rootfs-remove.list" ] && WANT_TRANSFORM=1
    if [ -d "$BOARD/rootfs-overlay-full" ] && \
       [ -n "$(find "$BOARD/rootfs-overlay-full" \( -type f -o -type l \) 2>/dev/null | head -1)" ]; then
        WANT_TRANSFORM=1
    fi
fi

if [ "$WANT_TRANSFORM" = 1 ]; then
    GT_BE98_ROOTFS_IMG="$IMG" "$BOARD/rootfs-transform.sh" "$BINARIES_DIR"
else
    cp -f "$IMG" "$BINARIES_DIR/rootfs.squashfs"
    echo "post-image-full: rootfs.squashfs = merlin rootfs.img VERBATIM ($(du -h "$IMG" | cut -f1))"
fi

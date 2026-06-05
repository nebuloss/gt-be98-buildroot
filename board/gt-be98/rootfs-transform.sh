#!/bin/sh
# GT-BE98 rootfs mutation pipeline (M3).
# Unpacks the validated ASUS rootfs blob, applies the in-repo transform
# (overlay + removal list + generated release marker), re-squashes with
# merlin's exact options, and emits rootfs.squashfs for post-image.sh.
#
# Verified preconditions (2026-06-05, see gt-be98-docs/flash-journal.md):
#  - the 0031 blob is squashfs 4.0, xz, 128K blocks;
#  - every inode in it is uid/gid 0/0 and there are NO special files
#    (b/c/s/p: zero) -> unprivileged unsquash + `mksquashfs -all-root`
#    round-trips ownership exactly; suid/mode bits survive extraction.
#
# Inputs (env):
#   GT_BE98_ROOTFS_IMG   the blob (default: located in $BUILD_DIR)
#   BINARIES_DIR ($1)    output dir
#   HOST_DIR             Buildroot host tools (mksquashfs/unsquashfs)
#   GT_BE98_RELEASE      release id (default: dev-$(git describe))
# Transform sources (in-repo, text only):
#   board/gt-be98/rootfs-overlay-full/   copied over the unpacked tree
#   board/gt-be98/rootfs-remove.list     one path per line, '#' comments;
#                                        each must exist (typo guard)
set -e

BINARIES_DIR="$1"
: "${BINARIES_DIR:?rootfs-transform.sh: BINARIES_DIR not given}"
: "${HOST_DIR:?rootfs-transform.sh: HOST_DIR not set}"
EXT="${BR2_EXTERNAL_GT_BE98_PATH:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)}"
BOARD="$EXT/board/gt-be98"

IMG="${GT_BE98_ROOTFS_IMG:-$(find "$BUILD_DIR" -name 'rootfs.img' -path '*gt-be98-rootfs*' | head -1)}"
[ -n "$IMG" ] && [ -f "$IMG" ] || { echo "rootfs-transform: blob rootfs.img not found"; exit 1; }

MKSQ="$HOST_DIR/bin/mksquashfs"; UNSQ="$HOST_DIR/bin/unsquashfs"
[ -x "$MKSQ" ] && [ -x "$UNSQ" ] || { echo "rootfs-transform: host squashfs-tools missing"; exit 1; }

WORK="$BINARIES_DIR/rootfs-transform.tmp"
rm -rf "$WORK"; mkdir -p "$WORK"
ROOT="$WORK/root"

echo "rootfs-transform: unpacking $(basename "$IMG")"
"$UNSQ" -q -d "$ROOT" "$IMG" >/dev/null

# sanity: refuse to proceed if extraction lost anything (count vs blob listing)
NBLOB=$("$UNSQ" -lln "$IMG" 2>/dev/null | wc -l)
NEXTR=$(find "$ROOT" | wc -l)
[ "$NEXTR" -ge "$NBLOB" ] || { echo "rootfs-transform: extraction incomplete ($NEXTR < $NBLOB)"; exit 1; }

# 1. removal list (M4 strip campaign). Every listed path MUST exist: a typo
#    silently "removing" nothing would fake progress.
RMLIST="$BOARD/rootfs-remove.list"
if [ -f "$RMLIST" ]; then
    grep -v '^\s*#' "$RMLIST" | grep -v '^\s*$' > "$WORK/rm.list" || true
    while IFS= read -r p; do
        rel="${p#/}"
        if [ -e "$ROOT/$rel" ] || [ -L "$ROOT/$rel" ]; then
            rm -rf "$ROOT/${rel:?}"
            echo "rootfs-transform: removed /$rel"
        else
            echo "rootfs-transform: FATAL - removal list entry not in rootfs: $p"
            exit 1
        fi
    done < "$WORK/rm.list"
fi

# 2. overlay
OVL="$BOARD/rootfs-overlay-full"
if [ -d "$OVL" ] && [ -n "$(find "$OVL" -type f -o -type l 2>/dev/null | head -1)" ]; then
    cp -a "$OVL"/. "$ROOT"/
    echo "rootfs-transform: overlay applied ($(find "$OVL" -type f | wc -l) files)"
fi

# 3. release marker (image identity for the validation gate).
#    NB /etc in this rootfs is a symlink to tmpfs (tmp/etc) - the marker must
#    live under the real /rom/etc.
GITSHA=$(git -C "$EXT" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)
DIRTY=$(git -C "$EXT" diff --quiet 2>/dev/null || echo "-dirty")
# version scheme: br-00NN, monotonic after merlin patch numbering (0031 was
# the last merlin-built release; the first Buildroot mutation is br-0032).
# Canonical value lives in board/gt-be98/RELEASE; override via GT_BE98_RELEASE.
REL="${GT_BE98_RELEASE:-$(cat "$BOARD/RELEASE" 2>/dev/null || echo dev)+g$GITSHA}"
BLOBV=$(sed -n 's/^GT_BE98_ROOTFS_VERSION = //p' "$EXT/package/gt-be98-rootfs/gt-be98-rootfs.mk")
BOOTV=$(sed -n 's/^GT_BE98_BOOTFS_VERSION = //p' "$EXT/package/gt-be98-bootfs/gt-be98-bootfs.mk")
cat > "$ROOT/rom/etc/gt-be98-release" <<EOF
release=$REL
buildroot_tree=$GITSHA$DIRTY
rootfs_blob=$BLOBV
bootfs_blob=$BOOTV
build_date=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF
echo "rootfs-transform: /rom/etc/gt-be98-release -> release=$REL tree=$GITSHA$DIRTY blobs=$BLOBV/$BOOTV"

# 4. re-squash with merlin's exact options (squashfs 4.0, xz, 128K, all-root)
OUT="$BINARIES_DIR/rootfs.squashfs"
rm -f "$OUT"
"$MKSQ" "$ROOT" "$OUT" -noappend -all-root -comp xz -b 131072 -no-progress >/dev/null
rm -rf "$WORK"
echo "rootfs-transform: wrote rootfs.squashfs ($(du -h "$OUT" | cut -f1), mutated from $(basename "$IMG"))"

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
#   board/gt-be98/br-busybox.links       pinned /usr/br applet-symlink set
#                                        (harvest parity guard, step 2b)
# Plus the from-source /usr/br binaries harvested out of $BUILD_DIR (step 2b):
# gt-be98-br-{busybox,dropbear,openssl} packages, never committed to git.
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

# 1b. rename list (e.g. daemon -> daemon.real for wrapper gating). Format:
#     "src dst" per line, paths absolute-in-rootfs. Both checked.
MVLIST="$BOARD/rootfs-rename.list"
if [ -f "$MVLIST" ]; then
    grep -v '^\s*#' "$MVLIST" | grep -v '^\s*$' > "$WORK/mv.list" || true
    while read -r src dst; do
        s="$ROOT/${src#/}"; d="$ROOT/${dst#/}"
        if [ -e "$s" ] || [ -L "$s" ]; then
            mv "$s" "$d"
            echo "rootfs-transform: renamed $src -> $dst"
        else
            echo "rootfs-transform: FATAL - rename source not in rootfs: $src"
            exit 1
        fi
    done < "$WORK/mv.list"
fi

# 2. overlay. `cp -a` stamps the overlay's OWN directory mode onto any
#    pre-existing ASUS directory the overlay also provides. Git does not track
#    directory modes, so an overlay dir's mode is just the builder's umask -- if
#    that dir SHADOWS a stock ASUS system dir (e.g. the br-0045 substitution
#    ships /usr/sbin/crond, dragging the overlay's 0775 /usr/sbin over the stock
#    0755 one) the result is an unintended, umask-dependent mode delta. Snapshot
#    the stock mode of every shadowed stock system dir, apply the overlay, then
#    restore those modes so the only deltas are files/symlinks. SHADOWED is the
#    list of stock dirs the substitution overlay reintroduces; /sbin and /usr
#    are already overlay-provided in the committed baseline (sbin/trial-deadman,
#    usr/br) so they are intentionally NOT restored -- leaving the baseline's
#    established modes untouched keeps the slice diff to the intended deltas.
OVL="$BOARD/rootfs-overlay-full"
if [ -d "$OVL" ] && [ -n "$(find "$OVL" -type f -o -type l 2>/dev/null | head -1)" ]; then
    SHADOWED="usr/sbin"
    SAVED="$WORK/dirmodes"; : > "$SAVED"
    for rel in $SHADOWED; do
        [ -d "$ROOT/$rel" ] && printf '%s %s\n' "$(stat -c '%a' "$ROOT/$rel")" "$rel" >> "$SAVED"
    done
    cp -a "$OVL"/. "$ROOT"/
    while read -r m rel; do chmod "$m" "$ROOT/$rel"; done < "$SAVED"
    echo "rootfs-transform: overlay applied ($(find "$OVL" -type f | wc -l) files; stock dir modes preserved: $SHADOWED)"
fi

# 2b. harvest the /usr/br island binaries (M5, br-0044): built FROM SOURCE by
#     the gt-be98-br-{busybox,dropbear,openssl} packages - the git overlay
#     carries only config/rails, never binaries. Copies EXACTLY the intended
#     files into the ASUS tree (no Buildroot skeleton/TARGET_DIR leakage):
#       /usr/br/bin/busybox + applet symlinks (pinned by br-busybox.links),
#       /usr/br/sbin/dropbearmulti, /usr/br/bin/openssl.
BRDST="$ROOT/usr/br"
mkdir -p "$BRDST/bin" "$BRDST/sbin"

BB_INST=$(find "$BUILD_DIR" -maxdepth 2 -type d -name '_install' -path '*gt-be98-br-busybox*' | head -1)
[ -n "$BB_INST" ] && [ -x "$BB_INST/bin/busybox" ] || { echo "rootfs-transform: FATAL - br-busybox _install not found (enable BR2_PACKAGE_GT_BE98_BR_BUSYBOX)"; exit 1; }
[ ! -e "$BB_INST/linuxrc" ] || { echo "rootfs-transform: FATAL - stray linuxrc in busybox _install"; exit 1; }
[ ! -d "$BB_INST/usr" ] || { echo "rootfs-transform: FATAL - busybox _install has usr/ (INSTALL_NO_USR lost)"; exit 1; }
cp -a "$BB_INST/bin/." "$BRDST/bin/"
cp -a "$BB_INST/sbin/." "$BRDST/sbin/"
# match the committed br-0043 /usr/br dir modes: the overlay ships /usr/br and
# /usr/br/etc at 0775, and `cp -a src/.` above stamps the busybox _install's
# 0755 onto bin/sbin - reset them to 0775 so the only rootfs deltas vs the
# baseline are the 3 rebuilt binaries + the release stamp.
chmod 0775 "$BRDST/bin" "$BRDST/sbin"

DBM=$(find "$BUILD_DIR" -maxdepth 2 -type f -name 'dropbearmulti' -path '*gt-be98-br-dropbear*' | head -1)
[ -n "$DBM" ] || { echo "rootfs-transform: FATAL - br-dropbear dropbearmulti not found (enable BR2_PACKAGE_GT_BE98_BR_DROPBEAR)"; exit 1; }
install -m 0755 "$DBM" "$BRDST/sbin/dropbearmulti"

OSSL=$(find "$BUILD_DIR" -maxdepth 3 -type f -name 'openssl' -path '*gt-be98-br-openssl*/apps/*' | head -1)
[ -n "$OSSL" ] || { echo "rootfs-transform: FATAL - br-openssl apps/openssl not found (enable BR2_PACKAGE_GT_BE98_BR_OPENSSL)"; exit 1; }
install -m 0755 "$OSSL" "$BRDST/bin/openssl"

# applet-parity guard: the produced symlink set must match the pinned
# manifest EXACTLY (any busybox config drift fails the build).
( cd "$BRDST" && find bin sbin -type l | sort ) > "$WORK/bb.links"
if ! cmp -s "$WORK/bb.links" "$BOARD/br-busybox.links"; then
    echo "rootfs-transform: FATAL - /usr/br applet links differ from br-busybox.links:"
    diff "$BOARD/br-busybox.links" "$WORK/bb.links" | head -20
    exit 1
fi

# static-linkage guard: none of the three may have PT_INTERP or DT_NEEDED.
if command -v readelf >/dev/null 2>&1; then
    for b in "$BRDST/bin/busybox" "$BRDST/sbin/dropbearmulti" "$BRDST/bin/openssl"; do
        if readelf -l "$b" 2>/dev/null | grep -q 'INTERP' || \
           readelf -d "$b" 2>/dev/null | grep -q 'NEEDED'; then
            echo "rootfs-transform: FATAL - $b is not fully static"
            exit 1
        fi
    done
fi
echo "rootfs-transform: /usr/br harvest OK (busybox $(stat -c%s "$BRDST/bin/busybox")B + $(wc -l < "$WORK/bb.links") links, dropbearmulti $(stat -c%s "$BRDST/sbin/dropbearmulti")B, openssl $(stat -c%s "$BRDST/bin/openssl")B)"

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

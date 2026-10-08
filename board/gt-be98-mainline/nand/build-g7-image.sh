#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# The G7 boot image (NAND-PHASE2.md, phase2/G7.md), made from an existing
# production build WITHOUT touching it: same kernel (the same Image.lzo, rescue
# initramfs and ROOTFS_URL inside), same rootfs.squashfs to serve; only the
# device tree differs: NAND=rw-jffs, i.e. the "image" partition is not marked
# read-only ("loader" stays read-only). Output: $OUT/images-g7/
#   ml-bootfs-g7.itb, gt-be98-os-g7.dtb, ml-bootfs-g7.info, ml-bootfs-g7.layout
#
#   sh board/gt-be98-mainline/nand/build-g7-image.sh
#
# Writing still needs, on the box: FENCE_VOLUMES=mltest in
# /etc/conf.d/gt-be98-jffs (default empty = read-only), which makes the
# service attach UBI with the write fence on mltest and set
# brcmnand.allow_write=1.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
CONF=${GT_BE98_LOCAL_CONF:-$HOME/.config/gt-be98-os/local.conf}
OUT= STOCK_BOOTFS=
. "$CONF"
I=$OUT/images
G=$OUT/images-g7
H=$OUT/host
SHARE=$H/share/gt-be98-mainline/mainline-boot
. "$OUT/build/gt-be98-linux.env"
export PATH="$H/bin:$H/sbin:$PATH"
die() { echo "build-g7-image: $*" >&2; exit 1; }
for f in "$I/Image.lzo" "$I/ml-bootfs.itb" "$I/dt/gt-be98-os.dts" "$I/dt/mlboot-bootargs.h" \
	"$I/rootfs.squashfs" "$STOCK_BOOTFS" "$SHARE/mkbootfs.py"; do
	[ -f "$f" ] || die "$f missing (run the production build first)"
done
grep -q 'NAND=ro$' "$I/ml-bootfs.info" || die "the production build is not NAND=ro"
# the production Image.lzo must be the one in the production itb
prod_k=$(sed -n '/(kernel)/,/Hash value/s/^ *Hash value: *//p' "$I/ml-bootfs.layout")
[ "$prod_k" = "$(sha256sum "$I/Image.lzo" | cut -d' ' -f1)" ] || die "Image.lzo is not the production itb's kernel"

rm -rf "$G"; mkdir -p "$G/dt"
cp "$I/dt/gt-be98-os.dts" "$I/dt/mlboot-bootargs.h" "$G/dt/"
cpp -nostdinc -undef -D__DTS__ -DML_USB -DML_PCIE -DML_PCIE_ALL \
	-DML_MPM_SIZE=0x10000000 -DML_NAND_RO -DML_NAND_RW_JFFS -x assembler-with-cpp \
	-I "$G/dt" -I "$SHARE" -I "$LINUX_DIR/arch/arm64/boot/dts/broadcom/bcmbca" \
	-I "$LINUX_DIR/scripts/dtc/include-prefixes" -I "$LINUX_DIR/include" \
	"$G/dt/gt-be98-os.dts" > "$G/dt/gt-be98-os.dts.pre"
dtc -q -I dts -O dtb -o "$G/gt-be98-os-g7.dtb" "$G/dt/gt-be98-os.dts.pre"
dtc -q -I dtb -O dts "$G/gt-be98-os-g7.dtb" > "$G/dt/gt-be98-os-g7.dtb.dts"
dtc -q -I dtb -O dts "$I/gt-be98-os.dtb" > "$G/dt/gt-be98-os-prod.dtb.dts"

# the only difference to the production DT: no read-only on "image"
diff "$G/dt/gt-be98-os-prod.dtb.dts" "$G/dt/gt-be98-os-g7.dtb.dts" > "$G/dt/dtb.diff" || true
[ "$(grep -c '^[<>]' "$G/dt/dtb.diff")" = 1 ] && grep -q '^< *read-only;' "$G/dt/dtb.diff" ||
	{ cat "$G/dt/dtb.diff"; die "the G7 DT differs from production by more than one read-only"; }
awk '/partition@/{p=1; ro=0; lab=""} p&&/label/{lab=$3} p&&/read-only/{ro=1} p&&/^\t*};/{if(!ro) print lab; p=0}' \
	"$G/dt/gt-be98-os-g7.dtb.dts" > "$G/dt/rw-partitions"
[ "$(cat "$G/dt/rw-partitions")" = '"image";' ] || die "only \"image\" may be writable"

rm -rf "$G/fit"
python3 "$SHARE/mkbootfs.py" "$STOCK_BOOTFS" "$I/Image.lzo" "$G/gt-be98-os-g7.dtb" \
	"$G/ml-bootfs-g7.itb" "$G/fit" >/dev/null
dumpimage -l "$G/ml-bootfs-g7.itb" > "$G/ml-bootfs-g7.layout"
g7_k=$(sed -n '/(kernel)/,/Hash value/s/^ *Hash value: *//p' "$G/ml-bootfs-g7.layout")
[ "$g7_k" = "$prod_k" ] || die "kernel differs from production"
fsz=$(stat -c %s "$G/ml-bootfs-g7.itb")
[ "$fsz" -le $((16 * 1048576)) ] || die "G7 FIT $fsz B > 16 MiB"
sha() { sha256sum "$1" | cut -d' ' -f1; }
{
	echo "GT-BE98 mainline OS, G7 image (NAND=rw-jffs: \"image\" writable in the DT; writes only through the UBI write fence, FENCE_VOLUMES=mltest on the box)"
	echo "built: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo "ml-bootfs-g7.itb: $fsz B sha256 $(sha "$G/ml-bootfs-g7.itb")"
	echo "kernel (Image.lzo, identical to production): sha256 $g7_k"
	echo "production ml-bootfs.itb: sha256 $(sha "$I/ml-bootfs.itb")"
	echo "rootfs.squashfs (the production one, serve unchanged): sha256 $(sha "$I/rootfs.squashfs")"
	echo "DT difference to production:"
	sed 's/^/  /' "$G/dt/dtb.diff"
} > "$G/ml-bootfs-g7.info"
cat "$G/ml-bootfs-g7.info"

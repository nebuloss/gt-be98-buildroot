#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# NAND phase-2 rehearsal under QEMU + nandsim (build host only; NAND-PHASE2.md
# gates G5-restore and G6). Nothing touches the box.
#
#   sh board/gt-be98-mainline/nand/rehearsal/run.sh [BACKUP_DIR]
#
# BACKUP_DIR (default ~/oe-tool/backup/nand-raw-20261008): the box's dumps;
# the CORRECTED ones (mtd*-ecc-oob.bin) provide the page data loaded into
# nandsim (the raw dumps keep the box's uncorrected bitflips and its 108-B
# controller OOB, which nandsim's 64-B software-BCH layout cannot use).
#
# Builds, in $SCRATCH (default /dev/shm/gt-be98-rehearsal):
#  - the kernel: 7.2.9 + the open-ethernet series + board/gt-be98-mainline/
#    patches/linux/*.patch (brcmnand read-only, MTD write fence, UBI fence),
#    the image's kernel config plus nandsim, software BCH, a UBI WL threshold
#    of 128 (instead of 4096, so wear-leveling really runs) and a QEMU
#    command line;
#  - static tools (mtd-utils, gt-be98-nandtool/-nandrestore/-ubileb) and
#    an initramfs with nand/rehearsal/init and the data;
# then boots it (QEMU virt, 6 GiB) and prints the GATE lines.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
EXT=$(cd "$HERE/../../../.." && pwd)
CONF=${GT_BE98_LOCAL_CONF:-$HOME/.config/gt-be98-os/local.conf}
OUT= BR2_DL_DIR=
. "$CONF"
BK=${1:-$HOME/oe-tool/backup/nand-raw-20261008}
S=${SCRATCH:-/dev/shm/gt-be98-rehearsal}
CC=${CC:-aarch64-linux-gnu-gcc}
. "$OUT/build/gt-be98-linux.env"
V=$LINUX_VERSION
CROSS=$OUT/host/bin/aarch64-buildroot-linux-gnu-
export PATH="$OUT/host/bin:$PATH"
mkdir -p "$S"

(cd "$BK" && sha256sum -c --quiet SHA256SUMS) || { echo "backup sha256 mismatch"; exit 1; }

# ---- kernel ---------------------------------------------------------------------
K=$S/linux-$V
if [ ! -f "$K/.gt-be98-done" ]; then
	rm -rf "$K"; mkdir -p "$K"
	tar -C "$K" --strip-components=1 -xJf "$BR2_DL_DIR/linux/linux-$V.tar.xz"
	while read -r p; do
		patch -s -p1 -d "$K" < "$OUT/build/gt-be98-kernel-series/$p"
	done < "$OUT/build/gt-be98-kernel-series/series"
	for p in "$EXT"/board/gt-be98-mainline/patches/linux/*.patch; do
		patch -s -p1 -d "$K" < "$p"
	done
	touch "$K/.gt-be98-done"
fi
O=$S/kbuild
mkdir -p "$O"
cp "$LINUX_DIR/.config" "$O/.config"
"$K/scripts/config" --file "$O/.config" \
	--set-str INITRAMFS_SOURCE "" \
	--set-str CMDLINE "console=ttyAMA0 rdinit=/init panic=-1 loglevel=6 nandsim.id_bytes=0xc2,0xda,0x90,0x95 nandsim.parts=16,2024 nandsim.bch=8 RH_LOOPS=${RH_LOOPS:-300}" \
	-e MTD_NAND_NANDSIM -e MTD_NAND_ECC_SW_BCH -e DEBUG_FS \
	--set-val MTD_UBI_WL_THRESHOLD 128
make -s -C "$K" O="$O" ARCH=arm64 CROSS_COMPILE="$CROSS" olddefconfig
for c in MTD_NAND_NANDSIM=y MTD_NAND_ECC_SW_BCH=y MTD_UBI_WL_THRESHOLD=128 MTD_UBI=y UBIFS_FS=y; do
	grep -qx "CONFIG_$c" "$O/.config" || { echo "kernel config: CONFIG_$c missing"; exit 1; }
done
grep -q '^# CONFIG_MTD_UBI_FASTMAP is not set' "$O/.config"
make -s -C "$K" O="$O" ARCH=arm64 CROSS_COMPILE="$CROSS" -j"$(nproc)" Image

# ---- tools ------------------------------------------------------------------------
T=$S/tools
rm -rf "$T"; mkdir -p "$T"
M=$(ls -d "$OUT"/build/mtd-[0-9]* | head -n1)
MF="-static -O2 -I$M/include -I$M -include $M/include/config.h"
ML="$M/lib/libmtd.c $M/lib/libmtd_legacy.c $M/lib/common.c $M/lib/libcrc32.c"
UL="$M/lib/libubi.c"
$CC $MF -o "$T/nanddump" "$M/nand-utils/nanddump.c" $ML
$CC $MF -o "$T/nandwrite" "$M/nand-utils/nandwrite.c" $ML
$CC $MF -o "$T/flash_erase" "$M/misc-utils/flash_erase.c" $ML
for u in ubiattach ubidetach ubinfo ubimkvol ubirmvol; do
	$CC $MF -o "$T/$u" "$M/ubi-utils/$u.c" $ML $UL
done
$CC -static -O2 -Wall -o "$T/gt-be98-nandtool" "$EXT/package/gt-be98-os/src/nandtool.c"
$CC -static -O2 -Wall -o "$T/gt-be98-nandrestore" "$HERE/../src/nandrestore.c"
$CC -static -O2 -Wall -o "$T/gt-be98-ubileb" "$HERE/../src/ubileb.c"

# ---- data -------------------------------------------------------------------------
Dd=$S/data
mkdir -p "$Dd"
cc -O2 -o "$S/nandtool-host" "$EXT/package/gt-be98-os/src/nandtool.c"
[ -f "$Dd/image.data" ] || "$S/nandtool-host" data "$BK/mtd1-image-ecc-oob.bin" 2048 108 > "$Dd/image.data"
[ -f "$Dd/loader.data" ] || "$S/nandtool-host" data "$BK/mtd0-loader-ecc-oob.bin" 2048 108 > "$Dd/loader.data"
[ "$(stat -c %s "$Dd/image.data")" = 265289728 ] || { echo "image.data size"; exit 1; }

# ---- initramfs ----------------------------------------------------------------------
L=$S/initramfs.list
{
	echo "dir /dev 0755 0 0"
	echo "nod /dev/console 0600 0 0 c 5 1"
	for d in /bin /sbin /tools /proc /sys /tmp /mnt /data; do echo "dir $d 0755 0 0"; done
	echo "file /bin/busybox $OUT/images/rescue/busybox 0755 0 0"
	echo "slink /bin/sh busybox 0777 0 0"
	echo "file /init $HERE/init 0755 0 0"
	for f in "$T"/*; do echo "file /tools/$(basename "$f") $f 0755 0 0"; done
	echo "file /data/image.data $Dd/image.data 0644 0 0"
	echo "file /data/loader.data $Dd/loader.data 0644 0 0"
} > "$L"
"$O/usr/gen_init_cpio" "$L" > "$S/rehearsal.cpio"

# ---- run ----------------------------------------------------------------------------
echo "booting the rehearsal (QEMU, up to ${RH_TIMEOUT:-5400} s)"
timeout "${RH_TIMEOUT:-5400}" qemu-system-aarch64 -M virt -cpu cortex-a53 -smp 4 -m 6144 \
	-nographic -no-reboot -kernel "$O/arch/arm64/boot/Image" \
	-initrd "$S/rehearsal.cpio" < /dev/null > "$S/console.log" 2>&1 || true
grep -aE '^(RH|GATE)' "$S/console.log" | sed 's/\r$//'
grep -aq 'RH-DONE' "$S/console.log" || { echo "REHEARSAL DID NOT COMPLETE (see $S/console.log)"; exit 1; }
grep -aq 'RH-SUMMARY pass [0-9]* fail 0' "$S/console.log" || exit 1
echo "REHEARSAL PASSED"

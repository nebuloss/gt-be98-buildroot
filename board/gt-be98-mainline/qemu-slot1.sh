#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# QEMU test of the slot-1 boot: rootfs from UBI vol 4 "rootfs1", NO network
# at all (no NIC, so no HTTP server can be reached), then the production
# /jffs handling (fenced read-write attach after the initramfs detached UBI,
# autosave, save on stop). Build host only.
#
#   board/gt-be98-mainline/qemu-slot1.sh [seconds]
#
# What runs, in QEMU "virt":
#  - the image kernel's source and .config (7.2.9 + the open-ethernet series
#    + board/gt-be98-mainline/patches/linux, i.e. with the write fence) plus
#    nandsim shaped like the box's NAND (Macronix ID, 2024-block "image"
#    partition) and a QEMU command line;
#  - a harness /init (stands for the box's previous life): loads the page
#    data of the box's NAND backup into nandsim (the box's UBI device: the
#    stock volumes, jffs2, vol 3/4), runs the kit's stock-slot1-flash.sh
#    exactly as on stock (resize vol 4, write the rootfs and the itb), then
#    re-enables the write gate and execs the image's real rescue /init;
#  - the image's rescue /init with an ml-defaults like post-image.sh writes
#    for NAND images (UBI_MTD = the nandsim partition, ROOTFS_SHA256/SIZE of
#    the test rootfs, a ROOTFS_URL that is never reachable);
#  - a test copy of the rootfs (the image's, plus a report script and
#    IMAGE_MTD = the nandsim partition, AUTOSAVE_INTERVAL=5).
# Prints the post-codes and the report; "SLOT1: PASS" at the end.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
EXT=$(cd "$HERE/../.." && pwd)
CONF=${GT_BE98_LOCAL_CONF:-$HOME/.config/gt-be98-os/local.conf}
OUT= BR2_DL_DIR=
. "$CONF"
WAIT=${1:-300}
S=${SCRATCH:-/dev/shm/gt-be98-slot1}
BK=${BACKUP:-$HOME/oe-tool/backup/nand-raw-20261008}
. "$OUT/build/gt-be98-linux.env"
V=$LINUX_VERSION
B=$OUT/images
HOSTB=$OUT/host/bin
CROSS=$HOSTB/aarch64-buildroot-linux-gnu-
CC=${CC:-aarch64-linux-gnu-gcc}
export PATH="$HOSTB:$PATH"
NANDSIM_MTD="NAND simulator partition 1"
mkdir -p "$S"

# ---- kernel: image source + board patches, image .config + nandsim ---------
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
	--set-str CMDLINE "console=ttyAMA0 earlycon=pl011,0x9000000 rdinit=/init ignore_loglevel panic=10 ml.usbmux=0 nandsim.id_bytes=0xc2,0xda,0x90,0x95 nandsim.parts=16,2024 nandsim.bch=8" \
	--set-str INITRAMFS_SOURCE "$S/initramfs.list" \
	-e PCI_HOST_GENERIC -e MTD_NAND_NANDSIM -e MTD_NAND_ECC_SW_BCH -e DEBUG_FS

# ---- static tools for the harness (mtd-utils of the build) ------------------
T=$S/tools
rm -rf "$T"; mkdir -p "$T"
M=$(ls -d "$OUT"/build/mtd-[0-9]* | head -n1)
MF="-static -O2 -I$M/include -I$M -include $M/include/config.h"
ML="$M/lib/libmtd.c $M/lib/libmtd_legacy.c $M/lib/common.c $M/lib/libcrc32.c"
$CC $MF -o "$T/nandwrite" "$M/nand-utils/nandwrite.c" $ML
for u in ubiattach ubidetach; do $CC $MF -o "$T/$u" "$M/ubi-utils/$u.c" $ML "$M/lib/libubi.c"; done
sh "$EXT/board/gt-be98-mainline/nand/build-phase2-kit.sh" > /dev/null
KIT=$B/nand-phase2-kit

# ---- data: the box's UBI device (corrected page data of the backup) --------
D=$S/data
mkdir -p "$D"
if [ ! -f "$D/image.data" ]; then
	(cd "$BK" && sha256sum -c --quiet SHA256SUMS)
	cc -O2 -o "$S/nandtool-host" "$EXT/package/gt-be98-os/src/nandtool.c"
	"$S/nandtool-host" data "$BK/mtd1-image-ecc-oob.bin" 2048 108 > "$D/image.data"
fi

# ---- test rootfs ---------------------------------------------------------------
R=$S/root
rm -rf "$R" "$D/root.sq"
cat > "$S/slot1.start" <<'EOF'
#!/bin/sh
sleep 5
r() { echo "SLOT1 $1: $2"; }
{
echo "=== SMOKE BEGIN"
. /etc/gt-be98-boot-info 2>/dev/null
r root_source "${BOOT_ROOT_SOURCE:-?}"
r jffs_status "$(tr '\n' ' ' < /run/gt-be98-jffs.status)"
r fence "$(grep -E '^(state|volumes|pebs|writes)' /sys/kernel/debug/ubi/ubi0/fence | tr '\n' ' ')"
r allow_write "$(cat /sys/module/brcmnand/parameters/allow_write)"
r jffs_mount "$(grep ' /jffs ' /proc/mounts)"
r ubi_volumes "$(for v in /sys/class/ubi/ubi0_*; do printf '%s:%s ' $(cat $v/name) $(cat $v/reserved_ebs); done)"
# autosave: a settings change reaches /jffs within two intervals (5 s here)
echo "slot1 $(date +%s)" > /etc/webui/slot1-test
sleep 14
[ "$(cat /jffs/mainline-os/state.digest 2>/dev/null)" = "$(gt-be98-save --digest)" ] &&
	r autosave PASS || r autosave FAIL
# nandcheck recorded
p=$(cat /run/gt-be98-jffs.nandcheck.pid 2>/dev/null); while [ -n "$p" ] && kill -0 $p 2>/dev/null; do sleep 1; done
r nandcheck "$(head -n 1 /run/gt-be98-nandcheck.result 2>/dev/null) $(grep -c '^vol ' /jffs/mainline-os/nandcheck.last 2>/dev/null) volumes recorded"
# save on stop, then a fresh fenced attach (the boot-time handover again)
echo "stop-save" > /etc/webui/slot1-stop
rc-service gt-be98-jffs stop >/dev/null 2>&1
r after_stop "ubi0=$([ -e /sys/class/ubi/ubi0 ] && echo attached || echo detached) allow_write=$(cat /sys/module/brcmnand/parameters/allow_write) jffs=$(grep -c ' /jffs ' /proc/mounts)"
rc-service gt-be98-jffs start >/dev/null 2>&1
tar -tzf /jffs/mainline-os/state.tgz 2>/dev/null | grep -q 'etc/webui/slot1-stop' && r save_on_stop PASS || r save_on_stop FAIL
r jffs_status_again "$(tr '\n' ' ' < /run/gt-be98-jffs.status)"
echo "=== messages:"; grep -E 'gt-be98-(jffs|save|nandcheck)|PERSISTENCE' /var/log/messages | tail -n 20
echo "=== SMOKE END"
} > /dev/console 2>&1
echo o > /proc/sysrq-trigger
EOF
"$HOSTB/fakeroot" -- sh -c "
	unsquashfs -q -d '$R' '$B/rootfs.squashfs' >/dev/null &&
	install -D -m 0755 '$S/slot1.start' '$R/etc/local.d/zz-slot1.start' &&
	sed -i -e 's/^IMAGE_MTD=.*/IMAGE_MTD=\"$NANDSIM_MTD\"/' -e 's/^AUTOSAVE_INTERVAL=.*/AUTOSAVE_INTERVAL=5/' '$R/etc/conf.d/gt-be98-jffs' &&
	ln -sf /etc/init.d/local '$R/etc/runlevels/default/local' &&
	mksquashfs '$R' '$D/root.sq' -comp xz -noappend -no-progress >/dev/null"
RSHA=$(sha256sum "$D/root.sq" | cut -d' ' -f1)
RSIZE=$(stat -c %s "$D/root.sq")
cp "$B/ml-bootfs.itb" "$D/ml-bootfs.itb"
ISHA=$(sha256sum "$D/ml-bootfs.itb" | cut -d' ' -f1)

# ---- harness /init + initramfs -------------------------------------------------
cat > "$S/harness" <<EOF
#!/bin/sh
/bin/busybox mkdir -p /usr/bin /usr/sbin /sbin
/bin/busybox --install -s
mount -t proc proc /proc; mount -t sysfs sysfs /sys; mount -t devtmpfs devtmpfs /dev
echo "HARNESS: loading the box's UBI device into nandsim"
echo 0 > /sys/module/nandsim/parameters/fence_writes
/tools/nandwrite -q /dev/mtd1 /data/image.data
/tools/ubiattach -m 1 -d 0 -O 2048 >/dev/null
echo "HARNESS: stock-slot1-flash.sh (as on stock)"
SLOT1_REHEARSAL=1 /kit/stock-slot1-flash.sh /data/root.sq $RSHA /data/ml-bootfs.itb $ISHA 2>&1 | sed 's/^/HARNESS: /'
/tools/ubidetach -d 0
echo 1 > /sys/module/nandsim/parameters/fence_writes
rm -f /data/image.data /data/root.sq /data/ml-bootfs.itb
umount /dev; umount /sys; umount /proc
exec /init.rescue
EOF
{
	echo 'WDT_MAX=600'; echo 'RESCUE=0'
	echo 'ROOTFS_URL=http://10.0.2.2:9/unreachable.squashfs'
	echo "UBI_MTD=\"$NANDSIM_MTD\""; echo 'UBI_ROOT_VOL=rootfs1'; echo 'UBI_VID_OFFSET=2048'
	echo "ROOTFS_SHA256=$RSHA"; echo "ROOTFS_SIZE=$RSIZE"
	echo 'USB_ROOT_WAIT=2'
} > "$S/ml-defaults"
sed -e "s|^file /etc/ml-defaults .*|file /etc/ml-defaults $S/ml-defaults 0644 0 0|" \
    -e "s|^file /init .*|file /init $S/harness 0755 0 0\nfile /init.rescue $B/rescue/init 0755 0 0|" \
	"$B/gt-be98-initramfs.list" > "$S/initramfs.list"
{
	echo "dir /tools 0755 0 0"; echo "dir /kit 0755 0 0"; echo "dir /data 0755 0 0"
	for f in "$T"/*; do echo "file /tools/$(basename "$f") $f 0755 0 0"; done
	for f in "$KIT"/*; do echo "file /kit/$(basename "$f") $f 0755 0 0"; done
	for f in image.data root.sq ml-bootfs.itb; do echo "file /data/$f $D/$f 0644 0 0"; done
} > "$S/data.list"
make -s -C "$K" O="$O" ARCH=arm64 CROSS_COMPILE="$CROSS" olddefconfig
for c in MTD_NAND_NANDSIM=y MTD_UBI=y UBIFS_FS=y; do
	grep -qx "CONFIG_$c" "$O/.config" || { echo "kernel config: CONFIG_$c missing"; exit 1; }
done
make -s -C "$K" O="$O" ARCH=arm64 CROSS_COMPILE="$CROSS" -j"$(nproc)" Image
"$O/usr/gen_init_cpio" "$S/data.list" > "$S/data.cpio"

# ---- boot: no network device at all ----------------------------------------------
echo "booting (QEMU, no NIC, up to $WAIT s)"
timeout "$WAIT" qemu-system-aarch64 -M virt -cpu cortex-a53 -smp 4 -m 4096 \
	-nographic -no-reboot -nic none -kernel "$O/arch/arm64/boot/Image" \
	-initrd "$S/data.cpio" < /dev/null > "$S/console.log" 2>&1 || true
sed 's/\x1b\[[0-9;]*[mK]//g; s/\r$//' "$S/console.log" > "$S/console.txt"
grep -aE 'HARNESS|BE98PC|INIT: (ubiroot|os|http|usbroot)' "$S/console.txt" | grep -v '^\[.*\] *$' || true
sed -n '/=== SMOKE BEGIN/,/=== SMOKE END/p' "$S/console.txt"
ok=1
grep -aq 'INIT: os: root from ubi:rootfs1' "$S/console.txt" || { echo "no root from ubi:rootfs1"; ok=0; }
grep -aq 'INIT: http: fetching' "$S/console.txt" && { echo "HTTP was tried"; ok=0; }
for k in 'SLOT1 jffs_status: mode=rw' 'SLOT1 autosave: PASS' 'SLOT1 save_on_stop: PASS' \
	'SLOT1 after_stop: ubi0=detached allow_write=N jffs=0' 'SLOT1 jffs_status_again: mode=rw' \
	'SLOT1 nandcheck: warn=0'; do
	grep -aq "$k" "$S/console.txt" || { echo "missing: $k"; ok=0; }
done
grep -aq '=== SMOKE END' "$S/console.txt" || { echo "no report (see $S/console.txt)"; ok=0; }
[ $ok = 1 ] && echo "SLOT1: PASS (rootfs from UBI vol 4, no network; fenced /jffs rw after the handover)" ||
	{ echo "SLOT1: FAIL"; exit 1; }

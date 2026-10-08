#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# QEMU smoke test of the OS userspace (build host only, no board hardware).
#
#   board/gt-be98-mainline/qemu-smoke.sh [seconds]
#
# Boots the built rootfs (images/rootfs.squashfs) with the real rescue
# /init on a QEMU "virt" machine and reports what OpenRC did. The image
# kernel cannot be used as is: its forced command line has the be98pc
# earlycon at 0xff802628, which does not exist in QEMU. So this builds, in a
# scratch directory, the same kernel (same tarball, same patch series, same
# .config) with a QEMU command line, and a test copy of the rootfs whose
# /etc/local.d/zz-smoke.start prints the service states and powers off.
# Expected in QEMU: no /dev/watchdog, so gt-be98-watchdog and the services
# that need it (gt-be98-drivers) do not start, and no network address.
#
# Needs: qemu-system-aarch64; the Buildroot output from build.sh; ~3 GB in
# $SCRATCH (default /dev/shm/gt-be98-qemu).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
CONF=${GT_BE98_LOCAL_CONF:-$HOME/.config/gt-be98-os/local.conf}
OUT= BR2_DL_DIR=
. "$CONF"
WAIT=${1:-120}
SCRATCH=${SCRATCH:-/dev/shm/gt-be98-qemu}
. "$OUT/build/gt-be98-linux.env"
HOSTB=$OUT/host/bin
CROSS=$HOSTB/aarch64-buildroot-linux-gnu-
export PATH="$HOSTB:$PATH"
V=${LINUX_VERSION}
mkdir -p "$SCRATCH"

# ---- kernel with a QEMU command line ---------------------------------------------
S=$SCRATCH/linux-$V
if [ ! -f "$S/.gt-be98-patched" ]; then
	rm -rf "$S"; mkdir -p "$S"
	tar -C "$S" --strip-components=1 -xJf "$BR2_DL_DIR/linux/linux-$V.tar.xz"
	while read -r p; do
		patch -s -p1 -d "$S" < "$OUT/build/gt-be98-kernel-series/$p"
	done < "$OUT/build/gt-be98-kernel-series/series"
	touch "$S/.gt-be98-patched"
fi
O=$SCRATCH/kbuild
mkdir -p "$O"
cp "$LINUX_DIR/.config" "$O/.config"
"$S/scripts/config" --file "$O/.config" \
	--set-str CMDLINE "console=ttyAMA0 earlycon=pl011,0x9000000 rdinit=/init ignore_loglevel panic=10 ml.usbmux=0" \
	--set-str INITRAMFS_SOURCE "$OUT/images/gt-be98-initramfs.list"
make -s -C "$S" O="$O" ARCH=arm64 CROSS_COMPILE="$CROSS" olddefconfig
make -s -C "$S" O="$O" ARCH=arm64 CROSS_COMPILE="$CROSS" -j"$(nproc)" Image

# ---- test rootfs -------------------------------------------------------------------
R=$SCRATCH/root
rm -rf "$R" "$SCRATCH/root.sq"
cat > "$SCRATCH/smoke.start" <<'EOF'
#!/bin/sh
sleep 5
{
echo "=== SMOKE BEGIN"
rc-status -a
echo "=== crashed:"; rc-status --crashed
echo "=== health:"; gt-be98-health
echo "=== mounts:"; cat /proc/mounts
echo "=== modules dir:"; ls /lib/modules/$(uname -r)/updates
echo "=== modinfo runner:"; modinfo -F vermagic bcm4916-runner
echo "=== sshd -t:"; /usr/sbin/sshd -t && echo ok
echo "=== messages:"; tail -n 30 /var/log/messages
echo "=== SMOKE END"
} > /dev/console 2>&1
echo o > /proc/sysrq-trigger
EOF
"$HOSTB/fakeroot" -- sh -c "
	unsquashfs -q -d '$R' '$OUT/images/rootfs.squashfs' >/dev/null &&
	install -D -m 0755 '$SCRATCH/smoke.start' '$R/etc/local.d/zz-smoke.start' &&
	ln -sf /etc/init.d/local '$R/etc/runlevels/default/local' &&
	mksquashfs '$R' '$SCRATCH/root.sq' -comp xz -noappend -no-progress >/dev/null"
printf 'file /rootfs.squashfs %s 0644 0 0\n' "$SCRATCH/root.sq" > "$SCRATCH/root.list"
"$LINUX_DIR/usr/gen_init_cpio" "$SCRATCH/root.list" > "$SCRATCH/root.cpio"

# ---- boot ------------------------------------------------------------------------------
timeout "$WAIT" qemu-system-aarch64 -M virt -cpu cortex-a53 -smp 4 -m 2048 \
	-nographic -no-reboot -kernel "$O/arch/arm64/boot/Image" \
	-initrd "$SCRATCH/root.cpio" < /dev/null > "$SCRATCH/console.log" 2>&1 || true
sed 's/\x1b\[[0-9;]*[mK]//g' "$SCRATCH/console.log" > "$SCRATCH/console.txt"
grep -aE 'BE98PC|INIT:|ERROR|failed|not found' "$SCRATCH/console.txt" | grep -v '^\[.*\] *$' || true
sed -n '/=== SMOKE BEGIN/,/=== SMOKE END/p' "$SCRATCH/console.txt"
grep -q '=== SMOKE END' "$SCRATCH/console.txt" && echo "SMOKE: reached the default runlevel" ||
	{ echo "SMOKE: FAILED (no report; see $SCRATCH/console.txt)"; exit 1; }

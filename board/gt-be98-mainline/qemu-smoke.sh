#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# QEMU smoke test of the OS userspace (build host only, no board hardware).
#
#   board/gt-be98-mainline/qemu-smoke.sh [seconds]
#
# Boots the built rootfs (images/rootfs.squashfs) with the real /init on a
# QEMU "virt" machine, the netroot way: a USB network adapter (qemu-xhci +
# usb-net), DHCP from QEMU, rootfs.squashfs + .sha256 fetched over HTTP from
# a server this script runs on the build host (10.0.2.2 inside QEMU), and
# reports what OpenRC did. The image
# kernel cannot be used as is: its forced command line has the be98pc
# earlycon at 0xff802628, which does not exist in QEMU. So this builds, in a
# scratch directory, the same kernel (same tarball, same patch series, same
# .config) with a QEMU command line, and a test copy of the rootfs whose
# /etc/local.d/zz-smoke.start prints the service states and powers off.
# Expected in QEMU: no /dev/watchdog, so gt-be98-watchdog and the services
# that need it (gt-be98-drivers) do not start, and no network address.
#
# SMOKE_WEBUI_PASSWORD=<pw>: provision a web UI password in the test copy
# and check that the webui starts and serves (otherwise: that it refuses).
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
	--set-str INITRAMFS_SOURCE "$SCRATCH/initramfs.list" \
	-e PCI_HOST_GENERIC -e USB_XHCI_PCI
# the image's initramfs, with a ROOTFS_URL pointing at this script's server
PORT=${PORT:-18098}
sed "s|^file /etc/ml-defaults .*|file /etc/ml-defaults $SCRATCH/ml-defaults 0644 0 0|" \
	"$OUT/images/gt-be98-initramfs.list" > "$SCRATCH/initramfs.list"
printf 'WDT_MAX=600\nRESCUE=0\nROOTFS_URL=http://10.0.2.2:%s/root.sq\n' "$PORT" \
	> "$SCRATCH/ml-defaults"
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
echo "=== netguard: enslave the lifeline into a bridge, expect it detached:"
ip link add br-smoke type bridge; ip link set br-smoke up
for i in /sys/class/net/usb* /sys/class/net/eth*; do [ -e "$i" ] && ip link set "${i##*/}" master br-smoke; done
sleep 3; echo "bridge ports now: $(ls /sys/class/net/br-smoke/brif 2>/dev/null | tr '\n' ' ')(expect none)"
ip link del br-smoke
if [ -f /etc/webui/auth.conf ]; then
echo "=== webui (password provisioned, enabled like the image: must run and serve):"
sleep 3; rc-service webui status 2>&1 | tail -1
curl -s -o /dev/null -w "http :80 -> %{http_code}\n" http://127.0.0.1/
curl -s -X POST -d "action=auth_status" http://127.0.0.1/api 2>/dev/null | head -c 200; echo
else
echo "=== webui guard (no password provisioned: webui must NOT start):"
rc-service webui start >/dev/null 2>&1; rc-service webui status 2>&1 | tail -1
pidof webui >/dev/null && echo "webui RUNNING (BAD)" || echo "webui not running (ok)"
fi
echo "=== regdb:"; iw reg reload && sleep 1; iw reg get | head -3
echo "=== postcode last:"; cat /run/gt-be98-postcode.last
echo "=== messages:"; tail -n 30 /var/log/messages
echo "=== SMOKE END"
} > /dev/console 2>&1
echo o > /proc/sysrq-trigger
EOF
"$HOSTB/fakeroot" -- sh -c "
	unsquashfs -q -d '$R' '$OUT/images/rootfs.squashfs' >/dev/null &&
	install -D -m 0755 '$SCRATCH/smoke.start' '$R/etc/local.d/zz-smoke.start' &&
	if [ -n '${SMOKE_WEBUI_PASSWORD:-}' ]; then
		salt=\$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \\n');
		printf 'SALT=%s\\nHASH=%s\\n' \$salt \$(printf '%s%s' \$salt '${SMOKE_WEBUI_PASSWORD:-}' | sha256sum | cut -d' ' -f1) > '$R/etc/webui/auth.conf';
		chmod 600 '$R/etc/webui/auth.conf';
		ln -sf /etc/init.d/gt-be98-webui-guard '$R/etc/runlevels/default/gt-be98-webui-guard';
		ln -sf /etc/init.d/webui '$R/etc/runlevels/default/webui';
	fi &&
	ln -sf /etc/init.d/local '$R/etc/runlevels/default/local' &&
	mksquashfs '$R' '$SCRATCH/root.sq' -comp xz -noappend -no-progress >/dev/null"
(cd "$SCRATCH" && sha256sum root.sq > root.sq.sha256)
(cd "$SCRATCH" && exec python3 -m http.server -b 127.0.0.1 "$PORT" >/dev/null 2>&1) &
HTTPD=$!
trap 'kill $HTTPD 2>/dev/null' EXIT
sleep 1

# ---- boot ------------------------------------------------------------------------------
timeout "$WAIT" qemu-system-aarch64 -M virt -cpu cortex-a53 -smp 4 -m 2048 \
	-nographic -no-reboot -kernel "$O/arch/arm64/boot/Image" \
	-device qemu-xhci -netdev user,id=n0 -device usb-net,netdev=n0 \
	< /dev/null > "$SCRATCH/console.log" 2>&1 || true
sed 's/\x1b\[[0-9;]*[mK]//g' "$SCRATCH/console.log" > "$SCRATCH/console.txt"
grep -aE 'BE98PC|INIT:|ERROR|failed|not found' "$SCRATCH/console.txt" | grep -v '^\[.*\] *$' || true
sed -n '/=== SMOKE BEGIN/,/=== SMOKE END/p' "$SCRATCH/console.txt"
grep -q '=== SMOKE END' "$SCRATCH/console.txt" && echo "SMOKE: reached the default runlevel" ||
	{ echo "SMOKE: FAILED (no report; see $SCRATCH/console.txt)"; exit 1; }

#!/bin/bash
# OpenRC-PID1 open-init rootfs assembly (BUILD-ONLY, no flash, no device).
#
# Produces a rootfs that is the br-0050 baseline with the ASUS rc PID1 REPLACED
# by OpenRC (openrc-init), keeping the pinned Broadcom graft and the open
# userspace. The graft early-init is preserved verbatim (bcm_boot_launcher +
# /rom/etc/rc3.d) and INVOKED by the OpenRC bcm-platform service.
#
# It overlays:
#   1. the OpenRC binaries from $OPENRC_STAGE (openrc-init, openrc-run, rc,
#      rc-status, rc-update, rc-service, openrc, libeinfo.so*, librc.so*)
#   2. this directory's init.d/* service scripts -> /etc/init.d/
#   3. the runlevel symlink layout -> /etc/runlevels/{sysinit,boot,default}/
#   4. /sbin/init  ->  /sbin/openrc-init   (the init swap)
#
# If $OPENRC_STAGE is absent (e.g. OpenRC could not be cross-compiled offline),
# the script STILL assembles the full overlay tree and reports the missing
# binaries, so the structure is build-ready the moment OpenRC binaries exist.
#
# Usage: openrc-assemble.sh <baseline-rootfs.img> <out-dir> [openrc-stage-dir]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BASE_IMG="${1:?baseline rootfs.img}"
OUT="${2:?out dir}"
OPENRC_STAGE="${3:-${OPENRC_STAGE:-}}"
UNSQ="${UNSQ:-/home/guillaume/be98/buildroot/output/host/bin/unsquashfs}"
MKSQ="${MKSQ:-/home/guillaume/be98/buildroot/output/host/bin/mksquashfs}"

# OpenRC files we expect from a cross-build (BR2_INIT_OPENRC target/).
OPENRC_BINS="sbin/openrc-init sbin/openrc sbin/rc bin/openrc-run bin/rc-status \
             bin/rc-update bin/rc-service bin/einfo bin/eend"
OPENRC_LIBS="lib/libeinfo.so lib/librc.so"

mkdir -p "$OUT"; FS="$OUT/openrc-rootfs"
rm -rf "$FS"
echo "== unsquash baseline =="
"$UNSQ" -d "$FS" "$BASE_IMG" >/dev/null || { echo "FATAL: unsquashfs failed"; exit 1; }

# IMPORTANT LAYOUT NOTE: on the merlin rootfs there is NO persistent /etc —
# `/etc -> tmp/etc` (runtime tmpfs) and `/etc/init.d -> /rom/etc/init.d`. The
# persistent config lives in the read-only /rom/etc. OpenRC config MUST therefore
# be installed under /rom/etc, and OpenRC built with --sysconfdir=/rom/etc so
# openrc-init reads /rom/etc/runlevels before the etc-farm service rebuilds /etc.
ETC="$FS/rom/etc"
echo "== overlay OpenRC service scripts into /rom/etc =="
mkdir -p "$ETC/init.d" "$ETC/runlevels/sysinit" \
         "$ETC/runlevels/boot" "$ETC/runlevels/default"
for s in "$HERE"/init.d/*; do
	install -m 0755 "$s" "$ETC/init.d/$(basename "$s")"
	echo "  + /rom/etc/init.d/$(basename "$s")"
done

echo "== runlevel symlinks (targets = /rom/etc/init.d/*, valid at runtime) =="
# sysinit: dead-man FIRST, etc-farm SECOND (rebuilds /etc), then stock VFS svcs.
for n in deadman-early etc-farm sysfs procfs devfs dmesg; do
	ln -sf "/rom/etc/init.d/$n" "$ETC/runlevels/sysinit/$n"
done
# boot: nvram -> platform graft -> hw-wdt -> lan/switch
for n in bcm-knvram bcm-platform hw-wdt net-switch; do
	ln -sf "/rom/etc/init.d/$n" "$ETC/runlevels/boot/$n"
done
# default: wifi glue + webui controller
for n in wifi-radio webui; do
	ln -sf "/rom/etc/init.d/$n" "$ETC/runlevels/default/$n"
done
echo "  runlevels populated under /rom/etc/runlevels"

echo "== overlay OpenRC binaries =="
MISSING=0
if [ -n "$OPENRC_STAGE" ] && [ -d "$OPENRC_STAGE" ]; then
	for f in $OPENRC_BINS $OPENRC_LIBS; do
		if [ -e "$OPENRC_STAGE/$f" ]; then
			install -D "$OPENRC_STAGE/$f" "$FS/$f"
			echo "  + /$f"
		else
			echo "  ! MISSING from stage: /$f"; MISSING=1
		fi
	done
else
	echo "  ! OPENRC_STAGE not provided/found — OpenRC binaries NOT overlaid."
	echo "    (offline: OpenRC 0.56 source not cached + no meson/ninja host tool)"
	MISSING=1
fi

echo "== /sbin/init swap =="
if [ -e "$FS/sbin/openrc-init" ]; then
	ln -sf /sbin/openrc-init "$FS/sbin/init"
	echo "  /sbin/init -> /sbin/openrc-init"
else
	echo "  ! /sbin/openrc-init absent — /sbin/init swap DEFERRED (still -> rc)"
	echo "    current: /sbin/init -> $(readlink "$FS/sbin/init" 2>/dev/null)"
fi

echo
echo "== overlay tree assembled at: $FS =="
if [ "$MISSING" -eq 0 ]; then
	SQ="$OUT/openrc-rootfs.squashfs"; rm -f "$SQ"
	"$MKSQ" "$FS" "$SQ" -noappend -all-root -comp xz -b 131072 -no-progress >/dev/null
	echo "== COMPLETE: $(stat -c%s "$SQ") bytes  sha=$(sha256sum "$SQ" | cut -d' ' -f1) =="
	exit 0
else
	echo "== INCOMPLETE: OpenRC binaries missing — squashfs NOT produced. =="
	echo "   Tree is build-ready; drop OpenRC binaries into a stage dir + re-run."
	exit 3
fi

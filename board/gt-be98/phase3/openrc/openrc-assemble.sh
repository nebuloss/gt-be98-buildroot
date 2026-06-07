#!/bin/bash
# OpenRC-PID1 open-init rootfs assembly (BUILD-ONLY, no flash, no device).
#
# Produces a rootfs that is the br-0050 baseline with the ASUS rc PID1 REPLACED
# by OpenRC (openrc-init), keeping the pinned Broadcom graft and the open
# userspace. The graft early-init is preserved verbatim (bcm_boot_launcher +
# /rom/etc/rc3.d) and INVOKED by the OpenRC bcm-platform service.
#
# OPENRC_STAGE is the Buildroot TARGET dir of the isolated openrc build
# (configs/gt-be98_openrc-init_defconfig -> output-openrc-init/target). OpenRC
# 0.56 is a meson build whose REAL install layout is:
#     /sbin/openrc-init /sbin/openrc /sbin/openrc-run /sbin/openrc-shutdown
#     /sbin/rc-update /sbin/rc-service        (note: in 0.56 `rc` IS `openrc`)
#     /bin/rc-status
#     /usr/lib/librc.so{,.1}  /usr/lib/libeinfo.so{,.1}
#     /usr/libexec/rc/**                       (librcdir helpers — REQUIRED)
#     /rom/etc/{rc.conf,conf.d,init.d,local.d,sysctl.d}  (sysconfdir=/rom/etc)
# OpenRC is built --sysconfdir=/rom/etc (blocker A: merlin /etc is a tmpfs;
# persistent config lives in read-only /rom/etc), so openrc-init looks for
# /rom/etc/runlevels + /rom/etc/init.d (verified in the binary strings).
#
# This script overlays, onto the unsquashed baseline:
#   1. the OpenRC binaries + libs + libexec from $OPENRC_STAGE (exact paths)
#   2. the stock OpenRC service scripts (devfs/procfs/sysfs/dmesg/...) +
#      conf.d + rc.conf into /rom/etc  (additive: merlin has no such names)
#   3. this directory's 8 custom init.d/* services -> /rom/etc/init.d/
#   4. the custom runlevel symlink layout -> /rom/etc/runlevels/{sysinit,boot,default}
#   5. /sbin/init -> /sbin/openrc-init   (the init swap; was -> rc)
# The graft (bcm_boot_launcher, wl.ko/dhd.ko/bcm_knvram.ko, nvram,
# bcm-base-drivers.sh, /rom/etc/rc3.d) is left byte-identical.
#
# Usage: openrc-assemble.sh <baseline-rootfs.img> <out-dir> [openrc-stage-dir]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BASE_IMG="${1:?baseline rootfs.img}"
OUT="${2:?out dir}"
OPENRC_STAGE="${3:-${OPENRC_STAGE:-/home/guillaume/be98/buildroot/output-openrc-init/target}}"
UNSQ="${UNSQ:-/home/guillaume/be98/buildroot/output/host/bin/unsquashfs}"
MKSQ="${MKSQ:-/home/guillaume/be98/buildroot/output/host/bin/mksquashfs}"
CEILING="${CEILING:-71106560}"   # slot-2 squashfs ceiling (bytes)

# OpenRC-owned files to lift from the stage (the REAL 0.56 buildroot layout).
OPENRC_BINS="sbin/openrc-init sbin/openrc sbin/openrc-run sbin/openrc-shutdown \
             sbin/rc-update sbin/rc-service bin/rc-status"
OPENRC_LIBS="usr/lib/librc.so usr/lib/librc.so.1 \
             usr/lib/libeinfo.so usr/lib/libeinfo.so.1"

mkdir -p "$OUT"; FS="$OUT/openrc-rootfs"
rm -rf "$FS"
echo "== unsquash baseline =="
"$UNSQ" -d "$FS" "$BASE_IMG" >/dev/null || { echo "FATAL: unsquashfs failed"; exit 1; }

# --- sanity: stage must hold a built openrc-init -----------------------------
if [ ! -x "$OPENRC_STAGE/sbin/openrc-init" ]; then
	echo "FATAL: no openrc-init in OPENRC_STAGE=$OPENRC_STAGE"
	echo "  build it: make ... O=output-openrc-init gt-be98_openrc-init_defconfig && make ... openrc"
	exit 2
fi

ETC="$FS/rom/etc"
MISSING=0
copy() { # src-rel
	if [ -e "$OPENRC_STAGE/$1" ]; then
		install -D -m "${2:-0755}" "$OPENRC_STAGE/$1" "$FS/$1"
		echo "  + /$1"
	else
		echo "  ! MISSING from stage: /$1"; MISSING=1
	fi
}

echo "== overlay OpenRC binaries =="
for f in $OPENRC_BINS; do copy "$f" 0755; done

echo "== overlay OpenRC libs (preserve .so -> .so.1 symlinks) =="
# cp -a to keep the versioned-soname symlinks intact.
mkdir -p "$FS/usr/lib"
for f in $OPENRC_LIBS; do
	if [ -e "$OPENRC_STAGE/$f" ] || [ -L "$OPENRC_STAGE/$f" ]; then
		cp -a "$OPENRC_STAGE/$f" "$FS/$f"; echo "  + /$f"
	else echo "  ! MISSING lib: /$f"; MISSING=1; fi
done

echo "== overlay /usr/libexec/rc (librcdir helpers) =="
if [ -d "$OPENRC_STAGE/usr/libexec/rc" ]; then
	mkdir -p "$FS/usr/libexec"
	cp -a "$OPENRC_STAGE/usr/libexec/rc" "$FS/usr/libexec/"
	echo "  + /usr/libexec/rc ($(find "$FS/usr/libexec/rc" -type f | wc -l) files)"
else echo "  ! MISSING /usr/libexec/rc"; MISSING=1; fi

echo "== overlay stock OpenRC /rom/etc config (rc.conf, conf.d, init.d, *.d) =="
mkdir -p "$ETC/init.d" "$ETC/conf.d"
[ -f "$OPENRC_STAGE/rom/etc/rc.conf" ] && { cp -a "$OPENRC_STAGE/rom/etc/rc.conf" "$ETC/rc.conf"; echo "  + /rom/etc/rc.conf"; }

# --- v3 LOGGING LAYER 1: OpenRC built-in service logger -> persistent /data ----
# rc.conf is sourced shell; appending wins over the stock commented defaults.
# This persists OpenRC's full service-execution log across the reboot/revert so
# a failed re-trial shows exactly which runlevel/service OpenRC reached.
echo "== v3 logging layer 1: rc_logger -> /data/openrc-rc.log (append to rc.conf) =="
{
	echo ''
	echo '# --- GT-BE98 open-init-v3 persistent boot logging (appended; last wins) ---'
	echo 'rc_logger="YES"'
	echo 'rc_log_path="/data/openrc-rc.log"'
} >> "$ETC/rc.conf"
grep -q '^rc_logger="YES"' "$ETC/rc.conf" && grep -q '^rc_log_path="/data/openrc-rc.log"' "$ETC/rc.conf" \
	&& echo "  + rc_logger=YES + rc_log_path=/data/openrc-rc.log [V]" \
	|| { echo "  ! rc.conf logging settings NOT applied"; MISSING=1; }
for d in conf.d local.d sysctl.d; do
	[ -d "$OPENRC_STAGE/rom/etc/$d" ] && { cp -a "$OPENRC_STAGE/rom/etc/$d/." "$ETC/$d/" 2>/dev/null || mkdir -p "$ETC/$d" && cp -a "$OPENRC_STAGE/rom/etc/$d/." "$ETC/$d/"; echo "  + /rom/etc/$d/"; }
done
# stock init.d service scripts (devfs/procfs/sysfs/dmesg/functions.sh/...) —
# additive: the merlin /rom/etc/init.d has none of these names.
nstk=0
for s in "$OPENRC_STAGE"/rom/etc/init.d/*; do
	[ -e "$s" ] || continue
	bn="$(basename "$s")"
	cp -a "$s" "$ETC/init.d/$bn"; nstk=$((nstk+1))
done
echo "  + $nstk stock /rom/etc/init.d/* scripts"

echo "== overlay the 8 GT-BE98 custom services =="
for s in "$HERE"/init.d/*; do
	[ -f "$s" ] || continue
	install -m 0755 "$s" "$ETC/init.d/$(basename "$s")"
	echo "  + /rom/etc/init.d/$(basename "$s")"
done

echo "== runlevels (rebuild fresh; targets = /rom/etc/init.d/*) =="
rm -rf "$ETC/runlevels"
mkdir -p "$ETC/runlevels/sysinit" "$ETC/runlevels/boot" "$ETC/runlevels/default"
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
echo "  sysinit: deadman-early etc-farm sysfs procfs devfs dmesg"
echo "  boot:    bcm-knvram bcm-platform hw-wdt net-switch"
echo "  default: wifi-radio webui"
# verify every runlevel symlink resolves to a real init.d script
DANGLE=0
for l in "$ETC"/runlevels/*/*; do
	tgt="$ETC/init.d/$(basename "$l")"
	[ -e "$tgt" ] || { echo "  ! DANGLING runlevel symlink: $l"; DANGLE=1; }
done
[ "$DANGLE" -eq 0 ] && echo "  all runlevel symlinks resolve [V]"

echo "== v3 logging layer 2: PID1 wrapper /sbin/init (+/sbin/openrc-init) =="
# The kernel exec()s /sbin/init (and the cmdline may name /sbin/openrc-init).
# Wire BOTH to a tiny #!/bin/sh wrapper that mounts /data, records "kernel
# reached userspace + about to exec init" + an early dmesg, then exec()s the
# REAL OpenRC PID1. The real ELF is renamed /sbin/openrc-init.real. This is the
# earliest-possible userspace capture — the layer the v2 trial (zero diagnostic)
# entirely lacked.
WRAP="$HERE/init-wrapper.sh"
if [ -f "$FS/sbin/openrc-init" ] && [ ! -L "$FS/sbin/openrc-init" ] && [ -f "$WRAP" ]; then
	# 1. preserve the real OpenRC PID1 binary
	mv "$FS/sbin/openrc-init" "$FS/sbin/openrc-init.real"
	chmod 0755 "$FS/sbin/openrc-init.real"
	# 2. wrapper at BOTH entry points (kernel /sbin/init AND any /sbin/openrc-init ref)
	rm -f "$FS/sbin/init"            # was a symlink -> openrc-init
	install -m 0755 "$WRAP" "$FS/sbin/init"
	install -m 0755 "$WRAP" "$FS/sbin/openrc-init"
	echo "  /sbin/openrc-init.real = real OpenRC PID1 (ELF)"
	echo "  /sbin/init             = wrapper ($(head -1 "$FS/sbin/init"))"
	echo "  /sbin/openrc-init      = wrapper (same)"
	# guard: wrapper must exec the .real, and the .real must exist + be ELF
	grep -q 'exec /sbin/openrc-init.real' "$FS/sbin/init" \
		&& [ -f "$FS/sbin/openrc-init.real" ] \
		&& echo "  wrapper -> exec /sbin/openrc-init.real [V]" \
		|| { echo "  ! wrapper wiring FAILED"; MISSING=1; }
else
	echo "  ! /sbin/openrc-init binary or wrapper absent — init wiring FAILED"; MISSING=1
fi

echo
echo "== overlay tree assembled at: $FS =="
if [ "$MISSING" -ne 0 ] || [ "$DANGLE" -ne 0 ]; then
	echo "== INCOMPLETE: missing OpenRC files or dangling runlevels — squashfs NOT produced. =="
	exit 3
fi
SQ="$OUT/GT-BE98_openrc-init_rootfs.squashfs"; rm -f "$SQ"
"$MKSQ" "$FS" "$SQ" -noappend -all-root -comp xz -b 131072 -no-progress >/dev/null
SZ=$(stat -c%s "$SQ")
echo "== squashfs: $SZ bytes  sha256=$(sha256sum "$SQ" | cut -d' ' -f1) =="
if [ "$SZ" -gt "$CEILING" ]; then
	echo "== FAIL: $SZ > slot-2 ceiling $CEILING =="; exit 4
fi
echo "== OK: under slot-2 ceiling $CEILING ($((CEILING - SZ)) bytes headroom) =="
echo "SQUASHFS=$SQ"
exit 0

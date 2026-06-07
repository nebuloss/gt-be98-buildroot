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

# --- v4 CHANGE 1: ALSO place librc.so.1 + libeinfo.so.1 in /lib ---------------
# DIAGNOSIS (v3 trial): openrc-init.real EXEC'd but DIED before any service, with
# an EMPTY /data/openrc-rc.log + zero breadcrumbs. NOT glibc (merlin libc.so.6 =
# Buildroot glibc 2.32 >= openrc-init's max req GLIBC_2.28). PRIME SUSPECT: the
# merlin dynamic linker (/lib/ld-linux.so.3) cannot FIND librc.so.1/libeinfo.so.1
# in /usr/lib because there is NO /etc/ld.so.cache and NO /etc/ld.so.conf, and the
# loader's hard-wired trusted dir is /lib (where libc.so.6 + ld-linux.so.3 live),
# NOT /usr/lib -> openrc-init fails at load before running anything.
# FIX (primary): copy the two OpenRC libs (32-bit ARM EABI5, matching
# /lib/libc.so.6 + /lib/ld-linux.so.3) into /lib, the always-searched glibc dir,
# and recreate the unversioned .so dev symlinks there. KEEP the /usr/lib copies.
echo "== v4 change 1: ALSO place librc.so.1 + libeinfo.so.1 in /lib (always-searched) =="
mkdir -p "$FS/lib"
for soname in librc.so.1 libeinfo.so.1; do
	if [ -e "$OPENRC_STAGE/usr/lib/$soname" ]; then
		install -m 0755 "$OPENRC_STAGE/usr/lib/$soname" "$FS/lib/$soname"
		echo "  + /lib/$soname"
	else
		echo "  ! MISSING for /lib: usr/lib/$soname"; MISSING=1
	fi
done
ln -sf librc.so.1    "$FS/lib/librc.so"
ln -sf libeinfo.so.1 "$FS/lib/libeinfo.so"
echo "  + /lib/librc.so -> librc.so.1 ; /lib/libeinfo.so -> libeinfo.so.1"

# --- v4 CHANGE 1 (belt-and-suspenders): ld.so.conf lists /lib+/usr/lib + cache --
# merlin /etc is a tmpfs (/etc -> tmp/etc) and /etc/ld.so.conf -> /rom/etc/ld.so.conf,
# so the PERSISTENT loader conf lives in read-only /rom/etc. The merlin base ALREADY
# ships /rom/etc/ld.so.conf listing /opt/lib /opt/usr/lib /lib /usr/lib — so the conf
# was never the gap; the missing piece at openrc-init load was the COMPILED
# /etc/ld.so.cache (ASUS rc builds it in sysinit, which openrc-init never reached).
# We ensure /lib + /usr/lib are listed and pre-build the cache. These are NOT relied
# on for the initial load (the /lib copy above is the primary, load-time fix), but
# the pre-built cache (baked into the squashfs /tmp/etc, visible before any tmpfs
# mount shadows it) is a genuine second path to resolving librc/libeinfo.
LDC="$FS/rom/etc/ld.so.conf"
mkdir -p "$FS/rom/etc"
[ -f "$LDC" ] || : > "$LDC"
for d in /usr/lib /lib; do
	grep -qxF "$d" "$LDC" 2>/dev/null || printf '%s\n' "$d" >> "$LDC"
done
echo "  + /rom/etc/ld.so.conf ensures /usr/lib + /lib (= $(tr '\n' ' ' < "$LDC"))"
TGT_LDCONFIG="${TGT_LDCONFIG:-/home/guillaume/be98/buildroot/output-openrc-init/host/arm-buildroot-linux-gnueabi/sysroot/sbin/ldconfig}"
QEMU_ARM="${QEMU_ARM:-$(command -v qemu-arm-static || command -v qemu-arm || true)}"
if [ -x "$TGT_LDCONFIG" ] && [ -n "$QEMU_ARM" ]; then
	# -X = build the cache ONLY, do NOT create/update soname symlinks (otherwise
	# ldconfig would mint stray links like /lib/libexpat.so.1 -> drift from base).
	# verify by grepping the compiled cache FILE directly (a piped `ldconfig -p |
	# grep -q` would SIGPIPE ldconfig and trip `pipefail` despite a valid cache).
	if "$QEMU_ARM" "$TGT_LDCONFIG" -X -r "$FS" -f /rom/etc/ld.so.conf -C /etc/ld.so.cache 2>/dev/null \
	   && [ -s "$FS/etc/ld.so.cache" ] \
	   && grep -qa 'librc\.so\.1' "$FS/etc/ld.so.cache"; then
		echo "  + /etc/ld.so.cache pre-built via qemu-arm + target ldconfig (contains librc.so.1) [V]"
	else
		echo "  ~ /etc/ld.so.cache not pre-built (non-fatal; /lib copy is the primary fix)"
	fi
else
	echo "  ~ no target ldconfig/qemu-arm -> /etc/ld.so.cache skipped (non-fatal; /lib copy is the fix)"
fi

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
	# v4 change 2 guard: the wrapper must redirect openrc-init's own stdout+stderr
	# to persistent /data so a load failure is RECORDED.
	grep -q 'exec /sbin/openrc-init.real "\$@" >> /data/openrc-init-out.log 2>&1' "$FS/sbin/init" \
		&& echo "  wrapper stderr-redirect -> /data/openrc-init-out.log [V]" \
		|| { echo "  ! wrapper stderr-redirect MISSING"; MISSING=1; }
	# v5 fix guard: the wrapper must pre-mount /run + create /run/openrc before exec
	grep -q 'mount -t tmpfs .* /run' "$FS/sbin/init" \
	   && grep -q 'mkdir -p /run/openrc' "$FS/sbin/init" \
		&& echo "  wrapper pre-mounts tmpfs /run + creates /run/openrc [V]" \
		|| { echo "  ! wrapper /run pre-mount MISSING"; MISSING=1; }
else
	echo "  ! /sbin/openrc-init binary or wrapper absent — init wiring FAILED"; MISSING=1
fi

# v4 change 1 guard: librc.so.1 + libeinfo.so.1 must ALSO be present in /lib
# (next to libc.so.6 / ld-linux.so.3), with the unversioned dev symlinks.
echo "== v4 verify: OpenRC libs ALSO in /lib =="
for soname in librc.so.1 libeinfo.so.1; do
	[ -f "$FS/lib/$soname" ] \
		&& echo "  /lib/$soname [V]" \
		|| { echo "  ! /lib/$soname MISSING"; MISSING=1; }
done
[ -L "$FS/lib/librc.so" ] && [ -L "$FS/lib/libeinfo.so" ] \
	&& echo "  /lib/{librc.so,libeinfo.so} dev symlinks [V]" \
	|| { echo "  ! /lib dev symlinks MISSING"; MISSING=1; }
# and the /usr/lib copies must be KEPT (belt-and-suspenders)
[ -f "$FS/usr/lib/librc.so.1" ] && [ -f "$FS/usr/lib/libeinfo.so.1" ] \
	&& echo "  /usr/lib copies KEPT [V]" \
	|| { echo "  ! /usr/lib copies missing"; MISSING=1; }

# --- v5 THE FIX: bake the /run mountpoint + fstab entry -----------------------
# CONCLUSIVE v4 diagnosis: openrc-init loops on fopen("/run/openrc/init.ctl")
# (OpenRC RC_INIT_FIFO, hardcoded to /run on Linux). The merlin RO-squashfs root
# has NO /run, so OpenRC's init.sh sysinit ABORTS ("The /run directory does not
# exist. Unable to continue.") -> no service -> init() returns -> mkfifo/fopen
# ENOENT loops forever. FIX: bake an empty /run dir into the image so init.sh's
# `[ -d /run ]` passes and a tmpfs can be mounted there. (The PID1 wrapper
# pre-mounts the tmpfs + creates /run/openrc before openrc-init's init().)
echo "== v5 fix: bake /run mountpoint into the rootfs =="
mkdir -p "$FS/run" && chmod 0755 "$FS/run"
[ -d "$FS/run" ] && echo "  + /run (0755) baked into image [V]" || { echo "  ! /run NOT baked"; MISSING=1; }
# belt-and-suspenders: add a tmpfs /run line to /rom/etc/fstab (base mounts only
# proc/var/mnt/sys). Idempotent; the wrapper mount is the primary path.
FSTAB="$FS/rom/etc/fstab"
if [ -f "$FSTAB" ]; then
	if grep -qE '^[^#]*[[:space:]]/run[[:space:]]' "$FSTAB"; then
		echo "  ~ /rom/etc/fstab already has a /run entry"
	else
		# the unsquashed fstab is read-only; restore the original mode afterwards
		FSTAB_MODE="$(stat -c '%a' "$FSTAB")"
		chmod u+w "$FSTAB"
		printf 'tmpfs\t\t/run\ttmpfs\tmode=0755,nosuid,nodev\t\t0\t0\n' >> "$FSTAB"
		chmod "$FSTAB_MODE" "$FSTAB"
		echo "  + /rom/etc/fstab: tmpfs /run entry appended (mode preserved $FSTAB_MODE)"
	fi
	grep -qE '[[:space:]]/run[[:space:]]' "$FSTAB" && echo "  + fstab /run entry present [V]" || { echo "  ! fstab /run entry missing"; MISSING=1; }
else
	echo "  ! /rom/etc/fstab absent (skipped fstab entry; wrapper mount is primary)"
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

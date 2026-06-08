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
# ★v8★: add start-stop-daemon + supervise-daemon. OpenRC's openrc-run.sh launches
# command-based services with command_background="yes" (e.g. the webui service) via
# `start-stop-daemon`. v7 never copied them -> webui's background launch had no
# start-stop-daemon. These are OpenRC's OWN binaries (from-source, /sbin), the exact
# helpers openrc-run.sh expects (the busybox.openrc applet exists too but OpenRC's
# own SSD matches the -m/-p/-b semantics openrc-run.sh uses).
OPENRC_BINS="sbin/openrc-init sbin/openrc sbin/openrc-run sbin/openrc-shutdown \
             sbin/rc-update sbin/rc-service bin/rc-status \
             sbin/start-stop-daemon sbin/supervise-daemon"
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

# === v9 FIX: libcap.so.2 in /lib (start-stop-daemon needs it -> webui) =========
# DIAGNOSIS (v8): /sbin/start-stop-daemon (the OpenRC helper that launches the
# webui service with command_background="yes") is `NEEDED: libcap.so.2`, but the
# br-0050 base ships only libcap-NG (libcap-ng.so.0) — NOT libcap.so.2. So SSD
# fails to load -> the webui background launch dies. FIX: install libcap.so.2
# from the OpenRC build sysroot (libcap 2.78, same ARM EABI5 / ld-linux.so.3 as
# the base libc) into /lib (the always-searched glibc dir, next to libc.so.6),
# with the soname + unversioned dev symlinks. The base has NO libcap.so.2, so
# this is purely additive (no graft object touched).
echo "== v9 fix: libcap.so.2 in /lib (start-stop-daemon dependency) =="
LIBCAP_SRC="${LIBCAP_SRC:-$OPENRC_STAGE/usr/lib/libcap.so.2.78}"
# fall back to the OpenRC host sysroot if the target copy is absent
if [ ! -e "$LIBCAP_SRC" ]; then
	for c in \
		/home/guillaume/be98/buildroot/output-openrc-init/host/arm-buildroot-linux-gnueabi/sysroot/usr/lib/libcap.so.2.78 \
		"$OPENRC_STAGE"/usr/lib/libcap.so.2* "$OPENRC_STAGE"/lib/libcap.so.2*; do
		[ -e "$c" ] && { LIBCAP_SRC="$c"; break; }
	done
fi
if [ -e "$LIBCAP_SRC" ]; then
	# verify it is the right ARM lib (EABI5) before placing it
	if file "$LIBCAP_SRC" 2>/dev/null | grep -q 'ELF 32-bit.*ARM'; then
		install -D -m 0755 "$LIBCAP_SRC" "$FS/lib/$(basename "$LIBCAP_SRC")"
		ln -sf "$(basename "$LIBCAP_SRC")" "$FS/lib/libcap.so.2"
		ln -sf libcap.so.2 "$FS/lib/libcap.so"
		echo "  + /lib/$(basename "$LIBCAP_SRC") (ARM EABI5) [V]"
		echo "  + /lib/libcap.so.2 -> $(basename "$LIBCAP_SRC") ; /lib/libcap.so -> libcap.so.2"
	else
		echo "  ! libcap source is NOT ARM ELF: $LIBCAP_SRC"; MISSING=1
	fi
else
	echo "  ! libcap.so.2 source MISSING (looked in $OPENRC_STAGE + sysroot)"; MISSING=1
fi

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

# === v6 THE FIX: a command-capable /bin/sh for OpenRC ========================
# DIAGNOSIS (v5 trial): OpenRC 0.56 now boots, mounts /proc, caches deps, and
# runs sysinit->boot->default — but EVERY service fails `command: not found`:
#   /usr/libexec/rc/sh/openrc-run.sh: line 292/407: command: not found
#   /usr/libexec/rc/sh/init.sh:        line 22:      command: not found
# Those are `#!/bin/sh` scripts, and the merlin /bin/busybox is BusyBox v1.25.1
# built WITHOUT CONFIG_ASH_CMDCMD -> the ash `command` builtin is ABSENT
# (confirmed: `busybox sh -c 'command -v ls'` -> "command: not found"). init.sh
# line 15 `command -v md5sum` then errored and fell through to the MISLEADING
# "md5sum is missing" eerror — md5sum is NOT actually missing (the merlin busybox
# HAS the md5sum applet and /usr/bin/md5sum -> ../../bin/busybox exists; `command`
# was the real failure). The Buildroot busybox 1.37.0 HAS both (CONFIG_ASH_CMDCMD=y
# + CONFIG_MD5SUM=y; GLIBC req <=2.28 <= merlin glibc 2.32 — ABI-compatible).
#
# WHY NOT replace /bin/busybox globally: the merlin busybox carries 25 applets the
# Buildroot busybox does NOT (depmod, bash, logread, nc, ntpd, zcip, blockdev,
# chpasswd, add-shell/remove-shell, mkfs.vfat, traceroute6, ...) that the closed
# graft early-init (bcm_boot_launcher children, S45bcm-*-drivers, /rom/etc/rc3.d)
# may invoke. A global swap would strip those from the graft's PATH applets and
# is NOT graft-safe. So we install the Buildroot busybox as a SEPARATE
# /bin/busybox.openrc (shadows nothing) and repoint ONLY OpenRC's own
# directly-exec'd librcdir shell scripts (#!/bin/sh) at it via
# `#!/bin/busybox.openrc sh`. openrc-run (C) execl()s openrc-run.sh, so EVERY
# service (incl. the 8 custom + stock VFS, all #!/sbin/openrc-run) inherits the
# command-capable shell; the openrc/rc binaries exec init.sh/init-early.sh the
# same way. The merlin /bin/sh + every graft #!/bin/sh script stay byte-untouched,
# and md5sum stays reachable via the existing /usr/bin/md5sum symlink. busybox is
# OPEN/GPL -> a legit from-source addition.
echo "== v6 fix: command-capable OpenRC shell (/bin/busybox.openrc) =="
BB_OPENRC_SRC="${BB_OPENRC_SRC:-$OPENRC_STAGE/bin/busybox}"
STRIP="${STRIP:-/home/guillaume/be98/buildroot/output-openrc-init/host/bin/arm-buildroot-linux-gnueabi-strip}"
if [ -x "$BB_OPENRC_SRC" ]; then
	install -D -m 0755 "$BB_OPENRC_SRC" "$FS/bin/busybox.openrc"
	if [ -x "$STRIP" ]; then
		"$STRIP" --strip-unneeded "$FS/bin/busybox.openrc" \
			&& echo "  + /bin/busybox.openrc (stripped, $(stat -c%s "$FS/bin/busybox.openrc") B)"
	else
		echo "  + /bin/busybox.openrc ($(stat -c%s "$FS/bin/busybox.openrc") B, NOT stripped — no target strip)"
	fi
	# repoint ONLY the directly-exec'd librcdir #!/bin/sh scripts (openrc-run.sh,
	# init.sh, init-early.sh, gendepends.sh, binfmt.sh, cgroup-release-agent.sh).
	# Sourced helpers (functions.sh, rc-*.sh, *-daemon.sh) carry NO shebang and
	# inherit the parent shell, so they need no change.
	nrw=0
	for f in "$FS"/usr/libexec/rc/sh/*.sh; do
		[ -f "$f" ] || continue
		if [ "$(head -1 "$f")" = "#!/bin/sh" ]; then
			sed -i '1s|^#!/bin/sh$|#!/bin/busybox.openrc sh|' "$f"
			nrw=$((nrw+1))
		fi
	done
	echo "  + rewrote $nrw /usr/libexec/rc/sh/*.sh shebangs -> #!/bin/busybox.openrc sh"
	# guards: busybox.openrc must be ELF; the two scripts in the v5 failure trace
	# (openrc-run.sh + init.sh) must now name busybox.openrc.
	head -c4 "$FS/bin/busybox.openrc" | grep -q $'\x7fELF' \
		&& echo "  /bin/busybox.openrc is ELF [V]" \
		|| { echo "  ! /bin/busybox.openrc not ELF"; MISSING=1; }
	grep -qx '#!/bin/busybox.openrc sh' "$FS/usr/libexec/rc/sh/openrc-run.sh" \
	  && grep -qx '#!/bin/busybox.openrc sh' "$FS/usr/libexec/rc/sh/init.sh" \
		&& echo "  openrc-run.sh + init.sh now use the command-capable shell [V]" \
		|| { echo "  ! shebang rewrite FAILED (openrc-run.sh/init.sh)"; MISSING=1; }
else
	echo "  ! busybox.openrc source MISSING at $BB_OPENRC_SRC"
	echo "    build it: make ... O=output-openrc-init busybox"
	MISSING=1
fi

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
# boot: nvram -> platform graft -> EARLY wired LAN + sshd reachability.
# v7 CHANGE: drop hw-wdt and net-switch from this runlevel; add net-lan.
#  - hw-wdt is REMOVED because it arms the watchdog in DAEMON mode (`wdtctl -d`)
#    which spawns wdtd to PING the HW watchdog every timeout/4 -> a hang would
#    NEVER reset (the v6 failure mode). v7 arms the watchdog in the PID1 wrapper
#    in DIRECT, NON-petting mode instead, so ANY hang resets. Petting MUST stay
#    off for the trial; the wrapper owns /dev/watchdog (single-open).
#  - net-switch (v6 stub: config_switch/config_extwan only) is SUPERSEDED by
#    net-lan, which also brings up br0 + the management IP + sshd :2222/:2223 so
#    the open-init is REACHABLE even if a later service hangs.
for n in bcm-knvram bcm-platform net-lan; do
	ln -sf "/rom/etc/init.d/$n" "$ETC/runlevels/boot/$n"
done
# default: wifi glue + webui controller + ★v22 watchdog-disarm LAST (boot-complete)★
for n in wifi-radio webui watchdog-disarm; do
	ln -sf "/rom/etc/init.d/$n" "$ETC/runlevels/default/$n"
done
echo "  sysinit: deadman-early etc-farm sysfs procfs devfs dmesg"
echo "  boot:    bcm-knvram bcm-platform net-lan   (v7: hw-wdt/net-switch dropped)"
echo "  default: wifi-radio webui watchdog-disarm   (v22: disarm wdt on committed boot)"
# verify every runlevel symlink resolves to a real init.d script
DANGLE=0
for l in "$ETC"/runlevels/*/*; do
	tgt="$ETC/init.d/$(basename "$l")"
	[ -e "$tgt" ] || { echo "  ! DANGLING runlevel symlink: $l"; DANGLE=1; }
done
[ "$DANGLE" -eq 0 ] && echo "  all runlevel symlinks resolve [V]"

# v7 REACHABILITY guards: net-lan must be present + linked into boot; the petting
# hw-wdt and the v6 net-switch stub must NOT be in any runlevel (they would defeat
# the non-petting watchdog / leave the LAN down).
echo "== v7 verify: net-lan service + runlevel wiring =="
[ -f "$ETC/init.d/net-lan" ] && echo "  /rom/etc/init.d/net-lan present [V]" \
	|| { echo "  ! net-lan service MISSING"; MISSING=1; }
[ -L "$ETC/runlevels/boot/net-lan" ] && echo "  net-lan linked into boot runlevel [V]" \
	|| { echo "  ! net-lan NOT in boot runlevel"; MISSING=1; }
if [ -e "$ETC/runlevels/boot/hw-wdt" ] || [ -e "$ETC/runlevels/boot/net-switch" ]; then
	echo "  ! v7: hw-wdt/net-switch still in boot runlevel (would pet wdt / no LAN)"; MISSING=1
else
	echo "  v7: hw-wdt + net-switch absent from runlevels (no watchdog petting) [V]"
fi
grep -q 'start_dropbear 2223' "$ETC/init.d/net-lan" && grep -q 'start_admin_dropbear' "$ETC/init.d/net-lan" \
	&& echo "  net-lan starts sshd :2222 admin + :2223 rescue [V]" \
	|| { echo "  ! net-lan sshd launch MISSING"; MISSING=1; }
# v10: the :2222 admin dropbear must be the faithful merlin replica — exact cmdline
# `dropbear -p 2222 -j -k`, /etc/dropbear hostkeys symlinked to /jffs/.ssh, and the
# admin authorized_keys sourced from nvram sshd_authkeys.
echo "== v10 verify: :2222 admin merlin-replica dropbear setup =="
grep -q 'dropbear -p 2222 -j -k\|"\$dbin" -p 2222 -j -k' "$ETC/init.d/net-lan" \
	&& echo "  net-lan: EXACT merlin cmdline dropbear -p 2222 -j -k [V]" \
	|| { echo "  ! net-lan missing merlin :2222 cmdline (-j -k)"; MISSING=1; }
grep -q '/jffs/.ssh/dropbear_${k}_host_key\|JFFS_SSH/dropbear_${k}_host_key' "$ETC/init.d/net-lan" \
	&& echo "  net-lan: /etc/dropbear hostkeys -> /jffs/.ssh (persistent, slot-shared) [V]" \
	|| { echo "  ! net-lan missing /jffs/.ssh hostkey symlinks"; MISSING=1; }
grep -q 'nvram get sshd_authkeys' "$ETC/init.d/net-lan" \
	&& echo "  net-lan: admin authorized_keys from nvram sshd_authkeys [V]" \
	|| { echo "  ! net-lan missing nvram sshd_authkeys authkey setup"; MISSING=1; }
# the deadman-early backstop must also (re)arm the watchdog
grep -q 'wdtctl -t 240 start' "$ETC/init.d/deadman-early" \
	&& echo "  deadman-early HW-watchdog backstop arm [V]" \
	|| { echo "  ! deadman-early watchdog backstop MISSING"; MISSING=1; }

# === v16 verify: faithful datapath (fc/rtpolicy) + SYN-probe + watcher ==========
echo "== v16 verify: datapath (fc enable/rtpolicy/allmulti) + syn_probe + watcher =="
grep -q 'fc enable' "$ETC/init.d/net-lan" \
	&& echo "  net-lan: fc enable (flow cache) [V]" \
	|| { echo "  ! net-lan missing fc enable"; MISSING=1; }
grep -q 'rtpolicy auto ALL' "$ETC/init.d/net-lan" \
	&& echo "  net-lan: rtpolicy auto ALL (runner policy) [V]" \
	|| { echo "  ! net-lan missing rtpolicy auto ALL"; MISSING=1; }
grep -q 'allmulti' "$ETC/init.d/net-lan" \
	&& echo "  net-lan: ALLMULTI on bridge + members [V]" \
	|| { echo "  ! net-lan missing ALLMULTI"; MISSING=1; }
grep -q 'syn_probe()' "$ETC/init.d/net-lan" && grep -q '/data/syn-probe.log' "$ETC/init.d/net-lan" \
	&& echo "  net-lan: v16 SYN-probe diagnostic (-> /data/syn-probe.log) [V]" \
	|| { echo "  ! net-lan missing v16 syn_probe"; MISSING=1; }
grep -q 'iptables -t raw -I PREROUTING -p tcp --dport 2230' "$ETC/init.d/net-lan" \
	&& echo "  net-lan: v18 layered SYN counters (raw/PREROUTING + INPUT :2230) [V]" \
	|| { echo "  ! net-lan missing v18 iptables SYN counters"; MISSING=1; }
grep -q 'iptables -F INPUT' "$ETC/init.d/net-lan" && grep -q '/data/firewall.log' "$ETC/init.d/net-lan" \
	&& echo "  net-lan: v19 INPUT firewall flush + ACCEPT + dump [V]" \
	|| { echo "  ! net-lan missing v19 firewall flush"; MISSING=1; }
grep -q 'iptables -I OUTPUT -p tcp --sport 2230' "$ETC/init.d/net-lan" && grep -q '/data/dropbear-2230.log' "$ETC/init.d/net-lan" \
	&& echo "  net-lan: v20 OUTPUT SYN-ACK counter + :2230 -E conn log [V]" \
	|| { echo "  ! net-lan missing v20 OUTPUT counter / dropbear -E log"; MISSING=1; }
grep -q 'ip route replace default via' "$ETC/init.d/net-lan" \
	&& echo "  net-lan: v21 DEFAULT ROUTE via lan_gateway (the fix) [V]" \
	|| { echo "  ! net-lan missing v21 default route"; MISSING=1; }
# ★v24★ wifi-radio must LOAD the wl driver (the graft bcm-wlan-drivers.sh is neutered)
grep -q 'load_wl_drivers' "$ETC/init.d/wifi-radio" && grep -q 'insmod "\$X/wl.ko" instance_base=0 intf_name=wl%d' "$ETC/init.d/wifi-radio" \
	&& echo "  v24: wifi-radio loads the wl driver (cfg80211 before wl.ko) [V]" \
	|| { echo "  ! v24 wifi-radio missing wl driver load"; MISSING=1; }
grep -q 'webui_radio_init=1' "$ETC/init.d/wifi-radio" \
	&& echo "  v24: wifi-radio arms EnsureRadio gates [V]" \
	|| { echo "  ! v24 wifi-radio missing EnsureRadio gate arming"; MISSING=1; }
# ★v22★ committable-baseline checks (admin user is verified AFTER the passwd bake below)
[ -L "$ETC/runlevels/default/watchdog-disarm" ] && [ -f "$ETC/init.d/watchdog-disarm" ] \
	&& echo "  v22: watchdog-disarm service in default runlevel (no commit boot-loop) [V]" \
	|| { echo "  ! v22 watchdog-disarm service missing/unlinked"; MISSING=1; }
grep -q '/data/.trial-armed' "$ETC/init.d/watchdog-disarm" && grep -q 'wdtctl ping' "$ETC/init.d/watchdog-disarm" && grep -q 'watchdog_keeper' "$ETC/init.d/watchdog-disarm" \
	&& echo "  v27: watchdog-keeper gates on /data/.trial-armed; committed=health-gated wdtctl-ping [V]" \
	|| { echo "  ! v27 watchdog-keeper petting/gating missing"; MISSING=1; }
[ -x "$FS/sbin/start-stop-daemon" ] \
	&& echo "  /sbin/start-stop-daemon present (webui background launch) [V]" \
	|| { echo "  ! /sbin/start-stop-daemon MISSING"; MISSING=1; }
[ -x "$FS/sbin/supervise-daemon" ] \
	&& echo "  /sbin/supervise-daemon present [V]" \
	|| { echo "  ! /sbin/supervise-daemon MISSING"; MISSING=1; }
# v8 etc-farm fix: must write fstab to the tmpfs, not RO /etc
grep -q '/tmp/etc/fstab' "$ETC/init.d/etc-farm" \
	&& echo "  etc-farm: writes fstab to /tmp/etc (tmpfs, not RO /rom/etc) [V]" \
	|| { echo "  ! etc-farm still writes /etc/fstab through RO symlink"; MISSING=1; }

# === v9 verify: net-lan self-diagnostics + libcap.so.2 ========================
echo "== v9 verify: net-lan self-diagnostics block + libcap.so.2 =="
grep -q 'run_diagnostics ' "$ETC/init.d/net-lan" \
	&& echo "  net-lan: backgrounded run_diagnostics invoked [V]" \
	|| { echo "  ! net-lan missing run_diagnostics call"; MISSING=1; }
grep -q '/data/net-diag.log' "$ETC/init.d/net-lan" \
	&& echo "  net-lan: writes /data/net-diag.log (persists revert) [V]" \
	|| { echo "  ! net-lan missing /data/net-diag.log"; MISSING=1; }
grep -q 'ping_test ' "$ETC/init.d/net-lan" \
	&& echo "  net-lan: connectivity self-test (ping PASS/FAIL) [V]" \
	|| { echo "  ! net-lan missing ping self-test"; MISSING=1; }
grep -qE 'netstat -ltn|ss -ltn' "$ETC/init.d/net-lan" \
	&& echo "  net-lan: listening-socket probe (netstat/ss) [V]" \
	|| { echo "  ! net-lan missing listening-socket probe"; MISSING=1; }
grep -q 'redact_mac' "$ETC/init.d/net-lan" \
	&& echo "  net-lan: MAC redaction in diagnostics (no MACs logged) [V]" \
	|| { echo "  ! net-lan diagnostics not redacting MACs"; MISSING=1; }
# libcap.so.2 must be present in /lib and be ARM ELF
if [ -e "$FS/lib/libcap.so.2" ]; then
	REAL="$FS/lib/$(readlink "$FS/lib/libcap.so.2")"
	if file "$REAL" 2>/dev/null | grep -q 'ELF 32-bit.*ARM'; then
		echo "  /lib/libcap.so.2 present + ARM ELF (start-stop-daemon dep) [V]"
	else
		echo "  ! /lib/libcap.so.2 target not ARM ELF"; MISSING=1
	fi
else
	echo "  ! /lib/libcap.so.2 MISSING"; MISSING=1
fi

# === v12 verify: admin-key perms fix + auth instrumentation ===================
echo "== v12 verify: :2222 admin-key perms fix (chown/chmod) + auth instrumentation =="
# explicit chown 0:0 + chmod on the dropbear-walked auth chain (umask-0000 safe)
grep -q 'chown 0:0' "$ETC/init.d/net-lan" \
	&& echo "  net-lan: explicit chown 0:0 on auth chain (uid0:gid0 like br-0045) [V]" \
	|| { echo "  ! net-lan missing chown 0:0 on auth chain"; MISSING=1; }
grep -q 'chmod 700' "$ETC/init.d/net-lan" && grep -q 'chmod 600' "$ETC/init.d/net-lan" \
	&& echo "  net-lan: chmod 700 (homedir/.ssh) + 600 (authorized_keys) [V]" \
	|| { echo "  ! net-lan missing chmod 700/600 on auth chain"; MISSING=1; }
# instrument (a): perms dump of the walked chain to net-diag.log
grep -q 'AUTH-CHAIN PERMS' "$ETC/init.d/net-lan" \
	&& echo "  net-lan: dumps auth-chain perms to /data/net-diag.log (no key bytes) [V]" \
	|| { echo "  ! net-lan missing auth-chain perms dump"; MISSING=1; }
# ★v13★ byte-match: net-lan must verify authkeys vs br-0045 sha and log RESULT.
grep -q 'RESULT: PASS authkeys byte-match' "$ETC/init.d/net-lan" \
	&& grep -q '6a09e22ceb71274f6b680b5037202f6d69d0b591edcfc4c5127362ee187d6364' "$ETC/init.d/net-lan" \
	&& echo "  net-lan: byte-match verify vs br-0045 authkeys sha + RESULT line [V]" \
	|| { echo "  ! net-lan missing v13 authkeys byte-match RESULT/sha"; MISSING=1; }
# instrument (b): ★v13★ debug dropbear on :2229 -> /data/dropbear-auth.log.
# v12 launched it as `-E -F -v` but -v is INVALID on dropbear v2025.88 (prints
# usage + exits, so :2229 never bound). v13 uses `-E -F -p 2229` (no -v).
grep -qF '"$dbin" -E -F -p 2229 -j -k' "$ETC/init.d/net-lan" \
	&& ! grep -qF '"$dbin" -E -F -v' "$ETC/init.d/net-lan" \
	&& echo "  net-lan: debug dropbear LAUNCH is -E -F -p 2229 (no invalid -v) [V]" \
	|| { echo "  ! net-lan :2229 launch not '-E -F -p 2229' (or stale -v in launch)"; MISSING=1; }
grep -q '/data/dropbear-auth.log' "$ETC/init.d/net-lan" \
	&& echo "  net-lan: :2229 auth verdicts -> /data/dropbear-auth.log (-E to stderr) [V]" \
	|| { echo "  ! net-lan missing /data/dropbear-auth.log redirect"; MISSING=1; }
# the original :2222 + :2223 must STILL be present (v12 is additive)
grep -qF '"$dbin" -p 2222 -j -k -P' "$ETC/init.d/net-lan" \
	&& echo "  net-lan: :2222 admin merlin cmdline KEPT [V]" \
	|| { echo "  ! v12 dropped the :2222 admin dropbear"; MISSING=1; }

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
	# v7 SAFETY guard: the wrapper must arm the HW watchdog (direct, NON-petting)
	grep -q 'wdtctl -t "\$WDT_TIMEOUT" start' "$FS/sbin/init" \
	   && grep -q '/dev/watchdog' "$FS/sbin/init" \
		&& echo "  v7: wrapper arms HW watchdog (wdtctl direct, no petting) [V]" \
		|| { echo "  ! v7 wrapper watchdog-arm MISSING"; MISSING=1; }
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

# --- v6 minor: make /etc/fstab resolve at do_sysinit (before etc-farm) -------
# v5 trial note: "/etc/fstab does not exist". OpenRC's init.sh do_sysinit runs
# `fstabinfo --mount /proc` + `/run` (lines 48/75) BEFORE any sysinit service, so
# it runs before etc-farm rebuilds /etc. At that point /etc -> tmp/etc is the
# BAKED skeleton, which has no fstab entry -> fstabinfo finds no /etc/fstab and
# warns (non-fatal: init.sh then mounts /proc//run directly; v5 confirmed /proc
# mounted). Bake a /tmp/etc/fstab -> /rom/etc/fstab symlink so fstabinfo resolves
# the real fstab (now incl. the /run line) at do_sysinit too. etc-farm's tmpfs
# rebuild re-creates the same symlink afterwards (its `for s in /rom/etc/*` loop).
if [ -d "$FS/tmp/etc" ] && [ ! -e "$FS/tmp/etc/fstab" ]; then
	ln -sf /rom/etc/fstab "$FS/tmp/etc/fstab"
	[ -L "$FS/tmp/etc/fstab" ] && echo "  + baked /tmp/etc/fstab -> /rom/etc/fstab (/etc/fstab at do_sysinit) [V]"
else
	echo "  ~ /tmp/etc/fstab already present or /tmp/etc absent (skipped)"
fi

# === v6 minor fix: daemon group/user for checkpath ===========================
# v5 trial: `checkpath: owner root:daemon not found`. The merlin rootfs ships NO
# /rom/etc/{passwd,group}; instead /etc/{passwd,group} -> /var/{passwd,group}
# were hand-built at runtime by ASUS rc's setup_passwd (GONE under OpenRC) on the
# tmpfs /var. So under OpenRC there is no group db at all -> getgrnam("daemon")
# fails -> checkpath cannot resolve root:daemon. FIX: provide a static, persistent
# group+passwd in READ-ONLY /rom/etc. etc-farm's `for s in /rom/etc/*` loop then
# symlinks /etc/{group,passwd} -> these, and because they live in /rom (never
# shadowed by the `mount -a` tmpfs /var that bcm-platform triggers) the daemon
# group stays resolvable through every runlevel. Minimal standard set incl. the
# reported `daemon` group/user. (Additive to /rom/etc — touches no graft object.)
echo "== v6 minor: bake /rom/etc/{group,passwd} (daemon group for checkpath) =="
if [ ! -e "$ETC/group" ]; then
	cat > "$ETC/group" <<'EOF'
root:x:0:
daemon:x:1:
bin:x:2:
sys:x:3:
adm:x:4:
tty:x:5:
disk:x:6:
lp:x:7:
mail:x:8:
kmem:x:9:
wheel:x:10:
audio:x:11:
cdrom:x:15:
dialout:x:18:
www-data:x:33:
operator:x:37:
ftp:x:45:
nogroup:x:65534:
EOF
	chmod 0644 "$ETC/group"
	grep -q '^daemon:x:1:' "$ETC/group" && echo "  + /rom/etc/group (incl daemon:x:1:) [V]" || { echo "  ! /rom/etc/group write failed"; MISSING=1; }
else
	echo "  ~ /rom/etc/group already present (left untouched)"
fi
if [ ! -e "$ETC/passwd" ]; then
	cat > "$ETC/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/sh
admin:x:0:0:admin:/root:/bin/sh
daemon:x:1:1:daemon:/usr/sbin:/bin/false
bin:x:2:2:bin:/bin:/bin/false
sys:x:3:3:sys:/dev:/bin/false
www-data:x:33:33:www-data:/var/www:/bin/false
operator:x:37:37:Operator:/var:/bin/false
nobody:x:65534:65534:nobody:/:/bin/false
EOF
	chmod 0644 "$ETC/passwd"
	grep -q '^daemon:x:1:1:' "$ETC/passwd" && echo "  + /rom/etc/passwd (incl daemon) [V]" || { echo "  ! /rom/etc/passwd write failed"; MISSING=1; }
else
	echo "  ~ /rom/etc/passwd already present (left untouched)"
fi
# ★v22★ admin user (uid0, HOME=/root) MUST be present so admin@:2222 auths like br-0045.
grep -q '^admin:x:0:0:.*:/root:' "$ETC/passwd" \
	&& echo "  v22: admin user (uid0, HOME=/root) in /rom/etc/passwd (admin@ auth) [V]" \
	|| { echo "  ! v22 admin user missing from /rom/etc/passwd"; MISSING=1; }

# === v23 FORCE-REBOOT — the open-init must REBOOT without hanging =============
# The base /sbin/reboot is a symlink -> rc, whose reboot applet signals PID1 assuming
# PID1==rc (Blocker E). Under openrc-init that triggers openrc-shutdown, which HANGS
# (graft daemons never stop) -> a hung reboot; with the watchdog disarmed that is a
# hard-hang needing a power-cycle (this bit us once). FIX: replace /sbin/reboot (and
# halt/poweroff) with a wrapper that forces an IMMEDIATE kernel reset — sync first
# (/data UBIFS is journaled/crash-safe), then reboot(2) via busybox -f, then sysrq-b.
# This NEVER goes through the hanging openrc-shutdown/rc path. The HW watchdog +
# bcm_bootstate are unaffected (they reset independently of /sbin/reboot).
echo "== v23: force-reboot wrapper (/sbin/{reboot,halt,poweroff}) =="
REBOOT_WRAP="$FS/sbin/reboot"
# preserve the original rc-symlink target name for reference (do not call it — it hangs)
[ -L "$FS/sbin/reboot" ] && echo "  (base /sbin/reboot -> $(readlink "$FS/sbin/reboot"); replacing)"
for f in reboot halt poweroff; do rm -f "$FS/sbin/$f"; done
cat > "$REBOOT_WRAP" <<'RBEOF'
#!/bin/sh
# v23 open-init force-reset: openrc-shutdown / rc-reboot HANG on the graft -> never use
# them. Sync, then immediate kernel reset. (/data UBIFS is journaled.)
sync; sync
/bin/busybox reboot -f 2>/dev/null
# fallback: sysrq immediate reset
echo 1 > /proc/sys/kernel/sysrq 2>/dev/null
echo b > /proc/sysrq-trigger 2>/dev/null
# last resort: raw reboot(2) via the kernel (should never reach here)
/bin/busybox reboot 2>/dev/null
RBEOF
chmod 0755 "$REBOOT_WRAP"
ln -sf reboot "$FS/sbin/halt"
ln -sf reboot "$FS/sbin/poweroff"
if head -1 "$REBOOT_WRAP" | grep -q '^#!/bin/sh' && grep -q 'busybox reboot -f' "$REBOOT_WRAP"; then
	echo "  v23: /sbin/reboot force-reset wrapper installed (+halt/poweroff symlinks) [V]"
else
	echo "  ! v23 force-reboot wrapper FAILED"; MISSING=1
fi
[ -x "$FS/bin/busybox" ] || echo "  ~ note: /bin/busybox presence not checked here (wrapper relies on it)"

# === v25 SLIM: strip unused components + de-blob the DPI stack ================
# Reads openrc-strip.list (this dir) and `rm -rf` each rootfs-relative path under
# $FS. Tolerant of already-absent paths. Runs AFTER all overlays so nothing we
# just installed is touched, and BEFORE mksquashfs so the removals shrink the
# image. The DPI engine objects (wred/dcd/libshn_*/usr/bwdpi) are in the list;
# libbwdpi.so + libbwdpi_sql.so are NOT removed but REPLACED with clean-room
# no-op stubs immediately afterward (KEEP binaries still DT_NEEDED them). The
# graft objects are NOT in the list, so the byte-identical graft is untouched.
STRIPLIST="${STRIPLIST:-$HERE/openrc-strip.list}"
echo "== v25 SLIM: strip unused components (openrc-strip.list) =="
if [ -f "$STRIPLIST" ]; then
	STRIP_BEFORE=$(command du -sb "$FS" 2>/dev/null | command cut -f1)
	nrm=0; nabs=0; freed=0
	while IFS= read -r rel; do
		# skip comments + blank lines
		case "$rel" in ''|\#*) continue;; esac
		rel="${rel#/}"                     # tolerate accidental leading slash
		tgt="$FS/$rel"
		if [ -e "$tgt" ] || [ -L "$tgt" ]; then
			sz=$(command du -sb "$tgt" 2>/dev/null | command cut -f1); sz=${sz:-0}
			rm -rf "$tgt"
			freed=$((freed + sz)); nrm=$((nrm + 1))
			echo "  - /$rel  (${sz}B)"
		else
			nabs=$((nabs + 1))
			echo "  ~ /$rel  (already absent)"
		fi
	done < "$STRIPLIST"
	STRIP_AFTER=$(command du -sb "$FS" 2>/dev/null | command cut -f1)
	echo "  strip total: removed $nrm path(s), $nabs already-absent; ~${freed}B (uncompressed) freed"
	echo "  \$FS uncompressed: ${STRIP_BEFORE}B -> ${STRIP_AFTER}B"
else
	echo "  ! openrc-strip.list MISSING at $STRIPLIST"; MISSING=1
fi

# === v25 DPI stub: install clean-room no-op libbwdpi{,_sql}.so ===============
# Compile (if needed) and overwrite $FS/usr/lib/libbwdpi.so + libbwdpi_sql.so
# with the no-op stubs. They export EXACTLY the symbols surviving consumers
# reference (49 FUNC + 6 OBJECT / 8 FUNC). 32-bit ARM EABI5, no SONAME (matches
# the originals). The .c lives in bwdpi-stub/; prebuilt .so are used if present.
echo "== v25 DPI stub: install no-op libbwdpi.so + libbwdpi_sql.so =="
STUBDIR="${STUBDIR:-$HERE/bwdpi-stub}"
STUB_CC="${STUB_CC:-/home/guillaume/be98/buildroot/output-openrc-init/host/bin/arm-buildroot-linux-gnueabi-gcc}"
STUB_NM="${STUB_NM:-/home/guillaume/be98/buildroot/output-openrc-init/host/bin/arm-buildroot-linux-gnueabi-nm}"
for pair in "libbwdpi.so:libbwdpi_stub.c" "libbwdpi_sql.so:libbwdpi_sql_stub.c"; do
	so="${pair%%:*}"; src="${pair##*:}"
	# (re)build the stub if the .so is absent or older than its source
	if [ ! -f "$STUBDIR/$so" ] || [ "$STUBDIR/$src" -nt "$STUBDIR/$so" ]; then
		if [ -x "$STUB_CC" ] && [ -f "$STUBDIR/$src" ]; then
			"$STUB_CC" -shared -fPIC -O2 -o "$STUBDIR/$so" "$STUBDIR/$src" \
				&& echo "  + compiled stub $so" \
				|| { echo "  ! stub compile FAILED: $so"; MISSING=1; }
		else
			echo "  ! cannot build stub $so (no CC or missing $src)"; MISSING=1
		fi
	fi
	if [ -f "$STUBDIR/$so" ]; then
		install -D -m 0755 "$STUBDIR/$so" "$FS/usr/lib/$so"
		echo "  + installed $FS/usr/lib/$so ($(command stat -c%s "$FS/usr/lib/$so")B)"
	else
		echo "  ! stub $so MISSING — cannot install"; MISSING=1
	fi
done
# verify the installed stubs are ARM ELF and export every required symbol
verify_stub_syms() { # so-path  required-symbol...
	local sop="$1"; shift
	command file "$sop" 2>/dev/null | command grep -q 'ELF 32-bit.*ARM' \
		|| { echo "  ! $(command basename "$sop") not ARM ELF"; MISSING=1; return; }
	local have miss=0
	have="$("$STUB_NM" -D --defined-only "$sop" 2>/dev/null | command awk '{print $3}')"
	for s in "$@"; do
		printf '%s\n' "$have" | command grep -qx "$s" || { echo "  ! $(command basename "$sop") MISSING symbol: $s"; miss=1; MISSING=1; }
	done
	[ "$miss" -eq 0 ] && echo "  $(command basename "$sop"): all $# required symbols exported (ARM ELF) [V]"
}
verify_stub_syms "$FS/usr/lib/libbwdpi.so" \
	AiProtectionMonitor_InfectedEvent AiProtectionMonitor_mail_log MobileDevMode_restart \
	WRS_WBL_DEL_LIST WRS_WBL_GET_PATH WRS_WBL_WRITE_LIST auto_sig_check check_tcode_blacklist \
	check_tdts_module_exist data_collect_main device_info_main device_main dump_dpi_support \
	free_app_cat free_app_inf free_rule_db get_anomaly_main get_app_patrol_main get_fw_app_bw_clear \
	get_fw_mesh_extender get_fw_user_domain_list get_fw_user_list get_fw_vp_list get_fw_wrs_url_list \
	get_vp init_app_cat init_app_inf init_rule_db mesh_set_extender qosd_main redirect_page_status \
	run_dpi_engine_service search_app_cat search_app_inf setup_wrs_conf start_dc start_dpi_engine_service \
	start_wrs start_wrs_wbl_service stat_main stop_bwdpi_wred_alive stop_dpi_engine_service \
	tdts_check_wan_changed tm_eula_check tm_qos_main web_history_save wrs_app_main wrs_main wrs_url_main \
	file_path s_tcode_blacklist_tuple s_tcode_tuple s_tuple vpnc_profile vpnc_profile_num
verify_stub_syms "$FS/usr/lib/libbwdpi_sql.so" \
	bwdpi_cgi_mon_del_db bwdpi_cgi_mon_to_json bwdpi_maclist_db bwdpi_monitor_info \
	bwdpi_monitor_ips bwdpi_monitor_nonips bwdpi_monitor_stat get_web_hook

# === v25 SAFETY: DO-NOT-REMOVE invariant must still hold in $FS ==============
echo "== v25 verify: DO-NOT-REMOVE set intact in assembled \$FS =="
v25_present() { if [ -e "$FS/$1" ] || [ -L "$FS/$1" ]; then echo "  $1 present [V]"; else echo "  ! $1 MISSING"; MISSING=1; fi; }
v25_present usr/lib/libbwdpi.so
v25_present usr/lib/libbwdpi_sql.so
v25_present usr/lib/libsqlite3.so.0
v25_present usr/lib/libovpn.so
v25_present usr/lib/libssl.so.1.1
v25_present usr/lib/libcrypto.so.1.1
v25_present usr/sbin/wl
v25_present bin/nvram
v25_present usr/sbin/hostapd
v25_present usr/br/sbin/dropbearmulti
v25_present usr/br/libexec/sftp-server
if [ -d "$FS/lib/modules/4.19.294/extra" ] && [ "$(command find "$FS/lib/modules/4.19.294/extra" -type f | command wc -l)" -gt 0 ]; then
	echo "  /lib/modules/4.19.294/extra intact ($(command find "$FS/lib/modules/4.19.294/extra" -type f | command wc -l) files) [V]"
else
	echo "  ! /lib/modules/4.19.294/extra MISSING/empty"; MISSING=1
fi
[ -e "$FS/lib/modules/4.19.294/kernel/net/wireless/cfg80211.ko" ] \
	&& echo "  cfg80211.ko present [V]" || { echo "  ! cfg80211.ko MISSING"; MISSING=1; }
[ -d "$FS/rom/etc/rc3.d" ] && echo "  /rom/etc/rc3.d present [V]" || { echo "  ! /rom/etc/rc3.d MISSING"; MISSING=1; }

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

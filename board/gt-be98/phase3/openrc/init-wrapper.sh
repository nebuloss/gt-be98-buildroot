#!/bin/sh
# v3 PID1 wrapper (layer 2 of the persistent /data boot logging) — the EARLIEST
# possible userspace capture. The kernel exec()s this (installed at BOTH
# /sbin/init AND /sbin/openrc-init); the REAL OpenRC PID1 is /sbin/openrc-init.real.
#
# The v2 open-init trial failed to boot with ZERO diagnostic because OpenRC does
# not run the ASUS rc3.d breadcrumb rail. This wrapper mounts the persistent
# /data volume and records "the kernel reached userspace and exec'd init" + an
# early dmesg BEFORE handing off to openrc-init, so a failed re-trial reveals how
# far boot got. busybox sh/mount/dmesg/cat applets are present in the full base.
mount -t ubifs ubi:data /data 2>/dev/null || mount -t ext4 /dev/data /data 2>/dev/null
echo "$(cat /proc/uptime) PID1-wrapper: kernel exec-d init; mounting /data; about to exec openrc-init" >> /data/openrc-boot.log 2>/dev/null
dmesg > /data/openrc-dmesg-early.log 2>/dev/null

# === v7 ★SAFETY★: arm the HW watchdog EARLY (guaranteed reset-on-hang) =========
# v6 HUNG with NO auto-recovery: openrc-init booted further but the network never
# came up and the shell dead-man did NOT fire (a hung PID1 cannot reboot) -> the
# device was stuck on slot2 needing a physical power-cycle. v7's #1 job is a
# GUARANTEED reset-on-hang. We arm the SoC HW watchdog here, the EARLIEST userspace
# point (the kernel auto-mounts devtmpfs on /dev — fstab mounts only proc/var/mnt/sys
# — so /dev/watchdog, the built-in BCM HW wdt, is already present), in DIRECT mode
# with NO petting daemon: `wdtctl -t <T> start` (NOT `-d`, which would spawn wdtd to
# ping it). The BCM HW timer latches in hardware and keeps counting after wdtctl
# exits (the documented "wdtctl ... start / wdtctl stop" direct-control pair proves
# it persists across process exit). Nothing pets it -> ANY hang anywhere in boot
# resets the SoC within <T> seconds -> the ONCE trial slot is consumed -> the
# bootloader returns to the COMMITTED slot1 (GOOD = br-0045). This REPLACES the
# unreliable shell dead-man as the trial auto-revert.
# Timeout: wdtctl accepts [4..600]s (verified: validation is `timeout-4 <= 596`).
# We use 240s (generous: lets a healthy boot reach the orchestrator's disarm).
# ★DISARM (orchestrator, ONLY after a healthy+reachable boot is confirmed)★:
#     wdtctl stop          # stops the HW timer (direct-mode disarm)
# Re-armed idempotently as a backstop in the deadman-early sysinit service.
WDT_TIMEOUT=240
if [ -e /dev/watchdog ] && [ -x /bin/wdtctl ]; then
	if /bin/wdtctl -t "$WDT_TIMEOUT" start >> /data/openrc-boot.log 2>&1; then
		echo "$(cat /proc/uptime) PID1-wrapper: HW watchdog ARMED ${WDT_TIMEOUT}s (wdtctl direct, NO petting; disarm: 'wdtctl stop')" >> /data/openrc-boot.log 2>/dev/null
	else
		echo "$(cat /proc/uptime) PID1-wrapper: wdtctl arm FAILED (deadman-early will retry)" >> /data/openrc-boot.log 2>/dev/null
	fi
else
	echo "$(cat /proc/uptime) PID1-wrapper: /dev/watchdog or /bin/wdtctl absent here -> deferring arm to deadman-early" >> /data/openrc-boot.log 2>/dev/null
fi
# v5 THE FIX: pre-mount /run BEFORE handing off to openrc-init. CONCLUSIVE v4
# diagnosis (source+strace): openrc-init loops forever on
# fopen("/run/openrc/init.ctl") — OpenRC's RC_INIT_FIFO is hardcoded to /run on
# Linux (src/librc/rc.h). The merlin rootfs has NO /run (RO squashfs root;
# /var->tmp/var, /etc->tmp/etc; fstab mounts only proc/var/mnt/sys), and OpenRC's
# /usr/libexec/rc/sh/init.sh (sysinit do_sysinit) ABORTS if /run is absent:
# "The /run directory does not exist. Unable to continue." -> no service runs
# (empty rc.log) -> init() returns -> mkfifo/fopen(/run/openrc/init.ctl) ENOENT
# loops forever, filling /data. We mount a tmpfs on /run (the baked-in mountpoint
# now exists in the squashfs) and pre-create /run/openrc + /run/lock so the FIFO
# can be created. init.sh sees /run already mounted (mountinfo -q /run) and skips
# its own re-mount -> no conflict.
mount -t tmpfs -o mode=0755,nosuid,nodev tmpfs /run 2>/dev/null
mkdir -p /run/openrc /run/lock 2>/dev/null
echo "$(cat /proc/uptime) PID1-wrapper: mounted tmpfs /run; created /run/openrc + /run/lock" >> /data/openrc-boot.log 2>/dev/null
# v4 CHANGE 2: capture openrc-init.real's OWN stdout+stderr to persistent /data.
# The v3 trial proved openrc-init.real EXEC'd but DIED before any service with an
# EMPTY rc.log + zero breadcrumbs — so the failure message went to a console we
# never saw. Redirecting here RECORDS a dynamic-linker load failure (e.g.
# "error while loading shared libraries: librc.so.1: cannot open shared object
# file") to /data, which survives the reboot/revert. If v4 still fails to boot,
# /data/openrc-init-out.log will name the exact reason.
exec /sbin/openrc-init.real "$@" >> /data/openrc-init-out.log 2>&1

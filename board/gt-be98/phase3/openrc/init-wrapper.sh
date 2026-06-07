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
exec /sbin/openrc-init.real "$@"

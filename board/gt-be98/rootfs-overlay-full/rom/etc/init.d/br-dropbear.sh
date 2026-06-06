#!/bin/sh
# GT-BE98 M5 candidate 1 (rail S28): Buildroot-built dropbear 2025.89
# (static, key-auth only - password auth compiled out) as a PARALLEL
# listener on test port 2223. The stock ASUS dropbear on 2222 is untouched;
# this never replaces it until the M5 gate validates the new one across
# reboots. Per plans/init-migration-go-no-go.md: lives under /usr/br (NB /opt is a tmpfs symlink in this rootfs - the plan's "/opt/br" prefix is realized as /usr/br),
# started from the boot rail, rc stays PID1.
#
# Hostkey persists on /data (rail-mounted at S25, same guarantee as the
# dead-man) so the fingerprint is stable across boots/slots.
# Supervision: small babysitter loop (the plan's adopted pattern - ASUS
# watchdog only respawns ASUS daemons). Respawn capped to avoid a
# crash-loop hammering the system.

DBIN=/usr/br/sbin/dropbearmulti
KEYDIR=/data/br/dropbear
PORT=2223
PIDFILE=/tmp/br-dropbear.pid

case "$1" in
    start)
        [ -x $DBIN ] || exit 0
        mkdir -p $KEYDIR
        [ -f $KEYDIR/hostkey ] || $DBIN dropbearkey -t ed25519 -f $KEYDIR/hostkey >/dev/null 2>&1
        (
            N=0
            while [ $N -lt 20 ]; do
                $DBIN dropbear -F -r $KEYDIR/hostkey -p $PORT -P $PIDFILE >/dev/null 2>&1
                N=$((N+1))
                sleep 5
            done
        ) &
        ;;
    stop)
        [ -f $PIDFILE ] && kill "$(cat $PIDFILE)" 2>/dev/null
        ;;
    *) echo "usage: $0 {start|stop}" ;;
esac

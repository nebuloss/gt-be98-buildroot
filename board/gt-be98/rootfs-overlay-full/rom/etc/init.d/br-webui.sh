#!/bin/sh
# GT-BE98 M5 candidate 4 (rail S29): Buildroot-built webui-go (pure-Go static
# ARM) - the open management backend that replaces the ASUS GUI - launched as
# a PARALLEL listener on a loopback TEST port. It does NOT take over :80: the
# ASUS httpd on :80 stays running and is retired only later by patch-0033
# (plan-phase2-rc-drain.md P2-5/P2-6). The existing /jffs/webui instance (the
# live admin path on :8080/:8081/:8082) is also untouched - this rail proves
# the harvested /usr/br/sbin/webui binary boots from the rail across reboots
# before the cutover. rc stays PID1; only ASUS daemons get the ASUS watchdog.
#
# State (the rail's own SQLite DB, kept separate from the live /jffs instance
# to avoid DB-lock contention) persists on /data (rail-mounted at S25, same
# guarantee as the dead-man / br-dropbear hostkey).
#
# Test bind is loopback-only so it cannot collide with the live instance's
# managed admin-VLAN bindings (internal/api/adminbind.go) - an explicit host
# in -listen takes the legacy single-bind path. Static UI assets are served
# from the deployed /jffs/webui/www tree (read-only).
#
# BETA-AWARE (br-0046): a flash-free beta channel. If an executable
# /jffs/webui/webui.next is present it is launched in preference to the
# in-image /usr/br/sbin/webui, so a candidate webui can be soaked by dropping
# one file onto /jffs (no re-flash). The selected channel+version is logged via
# logger(1) (-> /jffs/syslog.log). Safety net: if the beta binary exits >=3
# times within ~60s (a crash-loop) the rail permanently falls back to the
# in-image binary for the rest of this boot and logs the demotion. The in-image
# binary is always present and trial-proven, so the worst case self-heals to a
# known-good webui without a reboot.
#
# Supervision: small babysitter loop (the M5 pattern - the ASUS watchdog only
# respawns ASUS daemons). Respawn capped to avoid a crash-loop hammering.

BININIMG=/usr/br/sbin/webui
BETABIN=/jffs/webui/webui.next
WWW=/jffs/webui/www
CONFDIR=/data/br/webui
LISTEN=127.0.0.1:8089
PIDFILE=/tmp/br-webui.pid
TAG=br-webui

log() { logger -t "$TAG" "$1"; }

# webui_ver BIN -> the version string baked in at build (-ldflags -X main.version),
# printed by `webui -version` ("webui <ver>"); println writes to stderr, hence 2>&1.
webui_ver() { "$1" -version 2>&1 | awk '{print $2; exit}'; }

case "$1" in
    start)
        # channel selection: beta (/jffs/webui/webui.next) wins if executable,
        # else the in-image binary.
        if [ -x "$BETABIN" ]; then
            BIN="$BETABIN"; CHAN=beta
        else
            BIN="$BININIMG"; CHAN=image
        fi
        [ -x "$BIN" ] || exit 0
        mkdir -p "$CONFDIR"
        log "starting webui channel=$CHAN bin=$BIN version=$(webui_ver "$BIN") listen=$LISTEN"
        (
            N=0
            FAILS=0
            WSTART=$(date +%s)
            while [ $N -lt 20 ]; do
                "$BIN" -listen "$LISTEN" -www "$WWW" -conf "$CONFDIR" >/dev/null 2>&1 &
                echo $! > "$PIDFILE"
                wait $!
                NOW=$(date +%s)
                # slide the crash window: a crash >60s after the window opened is
                # an isolated exit, not a loop -> reset the counter.
                if [ $((NOW - WSTART)) -gt 60 ]; then
                    WSTART=$NOW; FAILS=0
                fi
                FAILS=$((FAILS+1))
                # crash-fallback: beta died >=3x within ~60s -> demote to in-image
                # for the rest of this boot (mirrors the dropbear babysitter cap).
                if [ "$CHAN" = beta ] && [ $FAILS -ge 3 ]; then
                    log "beta webui ($BETABIN) crashed $FAILS times within ~60s; falling back to in-image $BININIMG"
                    BIN="$BININIMG"; CHAN=image
                    log "starting webui channel=$CHAN bin=$BIN version=$(webui_ver "$BIN") listen=$LISTEN"
                    FAILS=0; WSTART=$(date +%s)
                fi
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

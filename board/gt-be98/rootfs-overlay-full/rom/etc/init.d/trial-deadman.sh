#!/bin/sh
# GT-BE98 in-image dead-man launcher (bcm_boot_launcher rail, S26 — right
# after S25mount-fs). Baked into every Buildroot-mutated image (M3+) so the
# flash-trial Layer-B protection does not depend on the shared /jffs
# bootstrap hook surviving.
#
# /jffs (where the armed flag lives) is mounted later by ASUS rc, so wait
# for it in the background, then hand over to /sbin/trial-deadman (inert
# unless /jffs/.trial-armed exists). The wait (240s) plus the dead-man
# window still fires well before any operator-relevant timeout.

case "$1" in
    start)
        (
            T=0
            while [ $T -lt 240 ]; do
                if mount | grep -q ' /jffs '; then
                    exec /bin/sh /sbin/trial-deadman
                fi
                sleep 5
                T=$((T+5))
            done
        ) &
        ;;
    stop) ;;
    *) echo "usage: $0 {start|stop}" ;;
esac

#!/bin/sh
# GT-BE98 in-image dead-man launcher (bcm_boot_launcher rail, S26 — right
# after S25mount-fs). Baked into every Buildroot-mutated image (M3+) so the
# flash-trial Layer-B protection does not depend on rc getting far enough to
# mount /jffs (br-0033 incident: rc hung pre-/jffs and a /jffs-based flag
# was blind). The armed flag lives on /data, which S25mount-fs has ALREADY
# mounted by the time this runs — no waiting, no rc dependency.

case "$1" in
    start)
        /bin/sh /sbin/trial-deadman &
        ;;
    stop) ;;
    *) echo "usage: $0 {start|stop}" ;;
esac

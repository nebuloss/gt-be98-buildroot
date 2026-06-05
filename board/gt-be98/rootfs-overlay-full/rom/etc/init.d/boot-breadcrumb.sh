#!/bin/sh
# GT-BE98 boot breadcrumb logger (rail S27). Leaves forensic evidence on
# /data for boots that hang before the network comes up (no serial console
# on this device — without this, a wedged boot is undiagnosable).
# Writes uptime + process list + dmesg tail every 20 s for the first 10 min,
# then stops. Previous boot's log is rotated to .prev. Cost: ~100 KB/boot.

LOG=/data/boot-breadcrumb.log

case "$1" in
    start)
        [ -f $LOG ] && mv $LOG $LOG.prev 2>/dev/null
        (
            echo "=== boot breadcrumb start: $(date) (cmdline: $(cat /proc/cmdline 2>/dev/null | grep -o 'ubi.block=[0-9,]*'))" >> $LOG
            T=0
            while [ $T -lt 600 ]; do
                {
                    echo "--- T+${T}s uptime=$(cut -d' ' -f1 /proc/uptime 2>/dev/null)"
                    ps w 2>/dev/null | tail -12
                    dmesg 2>/dev/null | tail -4
                } >> $LOG 2>&1
                sync
                sleep 20
                T=$((T+20))
            done
            echo "=== breadcrumb done (10 min reached, boot presumed stable or evidence captured)" >> $LOG
            sync
        ) &
        ;;
    stop) ;;
    *) echo "usage: $0 {start|stop}" ;;
esac

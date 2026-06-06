#!/bin/bash
# GT-BE98 post-trial validation gate (flash-journal.md / mission spec section 5).
# Run from the host AFTER a trial boot answered on SSH, BEFORE committing.
# Exit 0 = all gates passed. Prints a journal-ready report.
#
# Usage: gate-check.sh [--expect-slot N] [--expect-sha SHA256] [--quick]
#   --quick skips the 3-minute daemon-stability soak.
set -u

DEV="${GT_BE98_DEV:-admin@10.0.0.8}"; PORT="${GT_BE98_PORT:-2222}"
SSH="ssh -p $PORT -o ConnectTimeout=10 $DEV"
EXPECT_SLOT=""; EXPECT_SHA=""; QUICK=0
while [ $# -gt 0 ]; do
    case "$1" in
        --expect-slot) EXPECT_SLOT=$2; shift 2;;
        --expect-sha) EXPECT_SHA=$2; shift 2;;
        --quick) QUICK=1; shift;;
        *) echo "unknown arg $1" >&2; exit 1;;
    esac
done

PASS=0; FAIL=0
ok()   { echo "PASS: $*"; PASS=$((PASS+1)); }
bad()  { echo "FAIL: $*"; FAIL=$((FAIL+1)); }

echo "=== GT-BE98 validation gate $(date '+%F %T') ==="

# 1. SSH + slot identity (booted slot from cmdline - /proc/bootstate/active_image lies)
ACTIVE=$($SSH 'case "$(cat /proc/cmdline)" in *ubi.block=0,4*) echo 1;; *ubi.block=0,6*) echo 2;; esac' 2>/dev/null)
if [ -n "$ACTIVE" ]; then ok "SSH answers on :$PORT, booted slot=$ACTIVE"; else bad "SSH unreachable or slot undetectable"; echo "=== ABORT ==="; exit 1; fi
[ -n "$EXPECT_SLOT" ] && { [ "$ACTIVE" = "$EXPECT_SLOT" ] && ok "active slot == expected ($EXPECT_SLOT)" || bad "active slot $ACTIVE != expected $EXPECT_SLOT"; }

# 2. Image identity (release marker, present from M3 onward)
REL=$($SSH 'cat /rom/etc/gt-be98-release 2>/dev/null')
if [ -n "$REL" ]; then
    echo "--- /etc/gt-be98-release:"; echo "$REL" | sed 's/^/    /'
    [ -n "$EXPECT_SHA" ] && { echo "$REL" | grep -q "$EXPECT_SHA" && ok "release marker matches flashed sha" || bad "release marker does not contain $EXPECT_SHA"; }
else
    echo "INFO: no /etc/gt-be98-release (expected for pre-M3 images)"
fi

# 3. Radios up
for i in 0 1 2 3; do
    UP=$($SSH "wl -i wl$i isup 2>/dev/null")
    [ "$UP" = "1" ] && ok "radio wl$i up" || bad "radio wl$i not up (isup=$UP)"
done

# 4. User networks beaconing (baseline 2026-06-05: Ramondia/br20, Pagoa/br30, DEV-SCEP/br50)
HAPD=$($SSH 'for c in /tmp/webui-hapd/*.conf; do [ -f "$c" ] && grep -h "^ssid=" $c; done 2>/dev/null | sort -u')
for ssid in Ramondia Pagoa DEV-SCEP; do
    echo "$HAPD" | grep -q "^ssid=$ssid$" && ok "user net $ssid present (hostapd conf)" || bad "user net $ssid MISSING"
done
NHAPD=$($SSH 'ps w | grep -c "[h]ostapd"')
[ "$NHAPD" -ge 4 ] && ok "$NHAPD hostapd instances running" || bad "only $NHAPD hostapd instances"

# 5. Network basics. NB dnsmasq does NOT run on this AP (verified absent in
# the pre-flash 0031 baseline ps - AP mode, no DHCP served); don't require it.
$SSH 'ip addr show br0 | grep -q "inet "' && ok "br0 has an IP" || bad "br0 has no IP"
$SSH 'mount | grep -q "jffs.*rw"' && ok "jffs mounted rw" || bad "jffs not rw"
for d in eapd wlceventd mcpd watchdog; do
    $SSH "pidof $d >/dev/null" && ok "$d running" || bad "$d not running"
done

# 6. Crash health
BFC=$($SSH 'cat /proc/bootstate/boot_failed_count')
[ "$BFC" = "0" ] && ok "boot_failed_count=0" || bad "boot_failed_count=$BFC"
OOPS=$($SSH 'dmesg | grep -ciE "oops|panic|BUG:|segfault"' )
[ "$OOPS" = "0" ] && ok "dmesg clean (no oops/panic/BUG)" || bad "dmesg has $OOPS suspicious lines"

# 7. Daemon stability soak (3 min): key daemon pids must not change
if [ $QUICK = 0 ]; then
    echo "--- 3-minute daemon stability soak..."
    # dropbear: master listener pid only (session children incl. our own come
    # and go); others: full pidof
    SOAK='echo "dropbear-master $(cat /var/run/dropbear.pid 2>/dev/null)"; for d in eapd wlceventd mcpd watchdog; do echo "$d $(pidof $d | tr " " "\n" | sort -n | tr "\n" ",")"; done'
    SNAP1=$($SSH "$SOAK")
    sleep 180
    SNAP2=$($SSH "$SOAK")
    if [ "$SNAP1" = "$SNAP2" ]; then ok "daemon pids stable over 3 min"; else bad "daemon pids changed:"; diff <(echo "$SNAP1") <(echo "$SNAP2") | sed 's/^/    /'; fi
fi

echo "=== gate result: $PASS passed, $FAIL failed ==="
[ $FAIL = 0 ]

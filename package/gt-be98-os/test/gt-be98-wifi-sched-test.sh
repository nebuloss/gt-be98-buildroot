#!/bin/sh
# shellcheck shell=busybox
# SPDX-License-Identifier: GPL-2.0
# Offline test of sbin/gt-be98-wifi-sched (no device, no root):
#   sh test/gt-be98-wifi-sched-test.sh
# The clock (GT_BE98_CLOCK), date (GT_BE98_DATE) and the reload
# (GT_BE98_RELOAD) are fakes; the generator is the real one.
set -u
here=$(cd "$(dirname "$0")" && pwd)
S="$here/../src/sbin/gt-be98-wifi-sched"
G="$here/../src/sbin/gt-be98-wifi-gen"
SH=${SH:-sh}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0 n=0
check() {
	n=$((n + 1))
	if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want [$2] got [$3]"; fail=1; fi
}
export GT_BE98_CONFD="$T/confd" GT_BE98_RUN="$T/run" GT_BE98_WIFI_GEN="$G" FAKE="$T"
mkdir -p "$T/confd" "$T/run/gt-be98-wifi/gen" "$T/bin"
# date: prints $FAKE/date and records the TZ it ran with
printf '#!/bin/sh\necho "${TZ-unset}" > "$FAKE/tz"\ncat "$FAKE/date"\n' > "$T/bin/date"
printf '#!/bin/sh\necho reload >> "$FAKE/reloads"\n' > "$T/bin/reload"
chmod +x "$T/bin/"*
export GT_BE98_DATE="$T/bin/date" GT_BE98_RELOAD="$T/bin/reload"
# shellcheck disable=SC2034 # read by the script
now() { $SH "$S" now; }

# ---- now ----
echo '3 14:05' > "$T/date"
r=$(GT_BE98_CLOCK=synced now); check "now: prints D HH:MM" "3 14:05" "$r"
r=$(GT_BE98_CLOCK=unsynced now); c=$?; check "now: clock not synchronised -> nothing, exit 1" " 1" "$r $c"
echo 'garbage' > "$T/date"
r=$(GT_BE98_CLOCK=synced now); c=$?; check "now: an unreadable date -> exit 1" " 1" "$r $c"
echo '3 14:05' > "$T/date"
printf 'WIFI_SCHED_TZ="CET-1CEST,M3.5.0,M10.5.0/3"\n' > "$T/confd/gt-be98-wifi"
GT_BE98_CLOCK=synced now > /dev/null; check "now: TZ from conf.d" "CET-1CEST,M3.5.0,M10.5.0/3" "$(cat "$T/tz")"
printf 'WIFI_SCHED_TZ=UTC0\n' > "$T/confd/gt-be98-wifi-ap"
GT_BE98_CLOCK=synced now > /dev/null; check "now: the web UI file wins" "UTC0" "$(cat "$T/tz")"
printf 'WIFI_SCHED_TZ="UTC0; reboot"\n' > "$T/confd/gt-be98-wifi-ap"
GT_BE98_CLOCK=synced now > /dev/null; check "now: a TZ outside the charset is refused (UTC)" "unset" "$(cat "$T/tz")"
rm -f "$T/confd/gt-be98-wifi-ap" "$T/confd/gt-be98-wifi"

# ---- check ----
L="$T/nets"
printf 'WIFI_NETWORKS="%s"\n' "$L" > "$T/confd/gt-be98-wifi-ap"
{
	printf 'network=1\nssid=a\nsecurity=sae\npassphrase=password1\nbands=2g\nvlan=1\n'
	printf 'network=2\nssid=b\nsecurity=sae\npassphrase=password2\nbands=2g\nvlan=2\nschedule=weekdays@08:00-18:00\n'
} > "$L"
: > "$T/run/gt-be98-wifi/gen/plan"
tick() { : > "$T/reloads"; GT_BE98_CLOCK=${CLK:-synced} $SH "$S" check 2>/dev/null; echo "$? $(wc -l < "$T/reloads" | tr -d ' ')"; }
echo 'net 2 on' > "$T/run/gt-be98-wifi/gen/sched"
echo '1 09:00' > "$T/date"; check "check: running state = wanted: no reload" "0 0" "$(tick)"
echo '1 18:00' > "$T/date"; check "check: the window ended: one reload" "0 1" "$(tick)"
echo 'net 2 off' > "$T/run/gt-be98-wifi/gen/sched"
check "check: after that reload (state off): none" "0 0" "$(tick)"
echo '2 08:00' > "$T/date"; check "check: next window: one reload" "0 1" "$(tick)"
CLK=unsynced; check "check: clock lost: no reload (left as it runs)" "0 0" "$(tick)"; CLK=
mv "$T/run/gt-be98-wifi/gen/plan" "$T/plan.x"
check "check: the service runs no list: no reload" "0 0" "$(tick)"
mv "$T/plan.x" "$T/run/gt-be98-wifi/gen/plan"
cp "$L" "$L.keep"; printf 'network=3\nssid=c\nsecurity=psk2\npassphrase=password3\nbands=6g\nvlan=3\n' >> "$L"
check "check: a refused list: no reload" "0 0" "$(tick)"
sed '/^schedule=/d' "$L.keep" > "$L"
check "check: schedule removed while one is applied: one reload" "0 1" "$(tick)"
: > "$T/run/gt-be98-wifi/gen/sched"
check "check: no schedule, none applied: no reload, no generator run" "0 0" "$(GT_BE98_WIFI_GEN=/nonexistent tick)"
printf 'radio=2g\nschedule=daily@07:00-23:00\n' > "$L"; cat "$L.keep" >> "$L"
echo '1 23:30' > "$T/date"
check "check: a radio schedule off: one reload" "0 1" "$(tick)"
check "check: the generator's state for it" "net 2 off
radio 2g off" "$($SH "$G" -n "$L" -Q -T '1 23:30')"
check "usage: exit 2" 2 "$($SH "$S" bogus > /dev/null 2>&1; echo $?)"

if [ $fail = 0 ]; then echo "ALL OK ($n checks)"; else echo "FAILED"; fi
exit $fail

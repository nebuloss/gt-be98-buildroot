#!/bin/sh
# shellcheck shell=busybox
# SPDX-License-Identifier: GPL-2.0
# Offline test of sbin/gt-be98-wifi-reprobe (no device, no root):
#   sh test/gt-be98-wifi-reprobe-test.sh
# The netdevs (GT_BE98_SYSNET: <dev>/ifindex), the clock (GT_BE98_NOW) and
# the reload (GT_BE98_RELOAD) are fakes. The fake reload does what the
# service's reload does to the state (records the netdev's new ifindex in
# $STATE/ids) unless $FAKE/broken exists (a reload that fails the radio).
set -u
here=$(cd "$(dirname "$0")" && pwd)
R="$here/../src/sbin/gt-be98-wifi-reprobe"
SH=${SH:-sh}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0 n=0
check() {
	n=$((n + 1))
	if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want [$2] got [$3]"; fail=1; fi
}
export GT_BE98_RUN="$T/run" GT_BE98_SYSNET="$T/net" FAKE="$T" REPROBE_SETTLE=5 REPROBE_GONE=90 REPROBE_MIN=20 REPROBE_TRIES=3
I="$T/run/gt-be98-wifi/ids"
mkdir -p "$T/bin" "$T/net"
cat > "$T/bin/reload" <<'X'
#!/bin/sh
echo reload >> "$FAKE/reloads"
[ -f "$FAKE/broken" ] && exit 1
for f in "$FAKE"/run/gt-be98-wifi/ids/*; do
	d=${f##*/}; [ -f "$FAKE/net/$d/ifindex" ] && cp "$FAKE/net/$d/ifindex" "$f"
done
exit 0
X
# the daemon's messages: to a file (busybox sh runs its logger applet before PATH)
export GT_BE98_LOG="$T/log"; : > "$T/log"
chmod +x "$T/bin/"*
PATH="$T/bin:$PATH"
export GT_BE98_RELOAD="$T/bin/reload"
dev() { mkdir -p "$T/net/$1"; echo "$2" > "$T/net/$1/ifindex"; }	# dev NAME IFINDEX
gone() { rm -rf "${T:?}/net/$1"; }
at() {	# at SECONDS: one pass at that time; prints the reloads it ran
	: > "$T/reloads"; GT_BE98_NOW=$1 $SH "$R" check; echo "$? $(wc -l < "$T/reloads" | tr -d ' ')"
}

check "no ids (the service runs no radio): nothing" "0 0" "$(at 100)"
mkdir -p "$I"; dev bcawl0 10; dev bcawl3 13; echo 10 > "$I/bcawl0"; echo 13 > "$I/bcawl3"
check "every radio on its recorded netdev: no reload" "0 0" "$(at 100)"
gone bcawl0
check "bcawl0 gone (the re-probe under way): no reload" "0 0" "$(at 101)"
check "  said so" "yes" "$(grep -q 'bcawl0: netdev gone (ifindex 10)' "$T/log" && echo yes || echo no)"
dev bcawl0 20
check "bcawl0 back (ifindex 20) at 102: settling, no reload" "0 0" "$(at 102)"
check "  said so" "yes" "$(grep -q 'bcawl0: re-probed by the driver (ifindex 10 -> 20)' "$T/log" && echo yes || echo no)"
check "106 (4 s stable): still settling" "0 0" "$(at 106)"
check "107 (5 s stable): ONE reload" "0 1" "$(at 107)"
check "  the service recorded ifindex 20: nothing more" "0 0 20" "$(at 140) $(cat "$I/bcawl0")"
check "  bcawl3 never touched" "13" "$(cat "$I/bcawl3")"
# the ifindex changes again while settling: the settle starts over
dev bcawl3 23
check "bcawl3 re-probed (23) at 200: settling" "0 0" "$(at 200)"
dev bcawl3 33
check "bcawl3 re-probed again (33), seen at 206: the settle starts over" "0 0" "$(at 206)"
check "210 (4 s after 206): still settling" "0 0" "$(at 210)"
check "211: due, one reload" "0 1" "$(at 211)"
# a radio absent holds the others back, for REPROBE_GONE s at most
dev bcawl0 40; gone bcawl3
check "bcawl0 re-probed, bcawl3 gone, at 300: nothing" "0 0" "$(at 300)"
check "306: bcawl0 due, bcawl3 gone 6 s: held" "0 0" "$(at 306)"
check "389: bcawl3 gone 89 s: held" "0 0" "$(at 389)"
check "391: bcawl3 gone 91 s (its rebind failed): bcawl0 reloaded" "0 1" "$(at 391)"
check "  bcawl3 still absent, recorded 33: no reload for it" "0 0 33" "$(at 450) $(cat "$I/bcawl3")"
dev bcawl3 33
# one reload per REPROBE_MIN s, and REPROBE_TRIES reloads per ifindex at most
touch "$T/broken"; dev bcawl0 50
check "bcawl0 re-probed (50) at 500, the reload fails the radio: settling" "0 0" "$(at 500)"
check "505: reload 1" "0 1" "$(at 505)"
check "515: within REPROBE_MIN of the last: none" "0 0" "$(at 515)"
check "525: reload 2" "0 1" "$(at 525)"
check "545: reload 3" "0 1" "$(at 545)"
check "565: 3 tries spent on ifindex 50: none, said once" "0 0 1" "$(at 565) $(grep -c 'bcawl0: still not restarted after 3 reloads' "$T/log")"
check "600: still none, not said again" "0 0 1" "$(at 600) $(grep -c 'still not restarted' "$T/log")"
rm -f "$T/broken"; dev bcawl0 60
check "a new re-probe (60) starts over: settle at 700, reload at 705" "0 0|0 1" "$(at 700)|$(at 705)"
check "  recorded 60" "60" "$(cat "$I/bcawl0")"
# only bcawlN names, the rest ignored
echo 1 > "$I/eth0"; dev eth0 2
check "a non-radio name in ids: ignored" "0 0" "$(at 800)"
check "usage: exit 2" 2 "$($SH "$R" bogus > /dev/null 2>&1; echo $?)"

if [ $fail = 0 ]; then echo "ALL OK ($n checks)"; else echo "FAILED"; cat "$T/log"; fi
exit $fail

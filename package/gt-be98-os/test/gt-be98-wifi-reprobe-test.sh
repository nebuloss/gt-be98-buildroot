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
trap 'kill "${hapd_live:-}" 2>/dev/null; rm -rf "$T"' EXIT
fail=0 n=0
check() {
	n=$((n + 1))
	if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want [$2] got [$3]"; fail=1; fi
}
export GT_BE98_RUN="$T/run" GT_BE98_SYSNET="$T/net" FAKE="$T" REPROBE_SETTLE=5 REPROBE_GONE=90 REPROBE_MIN=20 REPROBE_TRIES=3
# the module list (GT_BE98_MODULES): the driver loaded unless a check unloads it
export GT_BE98_MODULES="$T/modules"; echo 'bca_pcie_ipc 4194304 0 - Live 0x0' > "$T/modules"
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

# ---- the supervision half (gt-be98-wifi: a radio that fails to start) ----
# hostapd_cli -i <bss> status: the state in $FAKE/state-<bss>
cat > "$T/bin/hostapd_cli" <<'X'
#!/bin/sh
while [ $# -gt 0 ]; do case $1 in -i) i=$2; shift 2 ;; -p) shift 2 ;; *) break ;; esac; done
echo "$i" >> "$FAKE/hcalls"
[ "$1" = status ] && [ -f "$FAKE/state-$i" ] && { read -r st < "$FAKE/state-$i"; printf 'freq=5180\nstate=%s\nphy=x\n' "$st"; }
exit 0
X
chmod +x "$T/bin/hostapd_cli"
rm -rf "$I" "$T/run/gt-be98-wifi/reprobe"; S="$T/run/gt-be98-wifi"
mkdir -p "$S/want" "$S/applied"
for d in bcawl0 bcawl3; do printf 'conf x\nfirst %s\nradio k-%s\n' "$d" "$d" > "$S/want/$d"; cp "$S/want/$d" "$S/applied/$d"; echo ENABLED > "$T/state-$d"; done
# hostapd itself alive (its pid file names a live process) for the radio cases
sleep 1000 & hapd_live=$!; echo "$hapd_live" > "$T/run/hostapd-wifi.pid"
check "supervision: both radios ENABLED: no reload" "0 0" "$(at 1000)"
echo DISABLED > "$T/state-bcawl0"
check "bcawl0 DISABLED, seen at 1001: not yet (REPROBE_DISABLED 10 s)" "0 0" "$(at 1001)"
check "  said so" "yes" "$(grep -q 'bcawl0: hostapd reports it DISABLED' "$T/log" && echo yes || echo no)"
check "1011 (10 s DISABLED, no record): one reload" "0 1" "$(at 1011)"
check "  the log names it" "yes" "$(grep -q 'supervision: failed:bcawl0: reloading' "$T/log" && echo yes || echo no)"
# a reload that exits non-zero (the service recorded the radio's failure): said as such, no promise of a retry in 20 s
printf '#!/bin/sh\necho reload >> "$FAKE/reloads"\nexit 1\n' > "$T/bin/reload-rc1"; chmod +x "$T/bin/reload-rc1"
: > "$S/reprobe/last.keep"; cp "$S/reprobe/last" "$S/reprobe/last.keep"; rm -f "$S/reprobe/last" "$S/reprobe/bcawl0.dis"; echo DISABLED > "$T/state-bcawl0"
n0=$(grep -c 'reload reported a failed radio' "$T/log")
GT_BE98_RELOAD="$T/bin/reload-rc1" GT_BE98_NOW=2500 $SH "$R" check; GT_BE98_RELOAD="$T/bin/reload-rc1" GT_BE98_NOW=2510 $SH "$R" check
check "a reload exiting non-zero: one 'reload reported a failed radio (see service log)', never 'retried in'" "1 0" \
	"$(( $(grep -c 'gt-be98-wifi reload reported a failed radio (see service log)' "$T/log") - n0 )) $(grep -c 'retried in' "$T/log")"
cp "$S/reprobe/last.keep" "$S/reprobe/last"
# the service recorded the failure: retry due at next=
printf 'dev=bcawl0\nkey=k-bcawl0\nstate=DISABLED\nreason=r\ntries=0\nnext=1041\ngiven_up=0\nsince=1011\n' > "$S/failed.tmp"; mkdir -p "$S/failed"; mv "$S/failed.tmp" "$S/failed/bcawl0"
check "record, next=1041: at 1035 nothing" "0 0" "$(at 1035)"
check "at 1041 (the retry is due): one reload" "0 1" "$(at 1041)"
sed -i 's/^next=.*/next=/' "$S/failed/bcawl0"; echo COUNTRY_UPDATE > "$T/state-bcawl0"
check "a retry running (next empty), the radio starting: nothing" "0 0" "$(at 1100)"
echo DISABLED > "$T/state-bcawl0"
check "  the retry failed (DISABLED again), seen at 1101: not yet" "0 0" "$(at 1101)"
check "  1111 (10 s): one reload (the service counts it, schedules the next)" "0 1" "$(at 1111)"
cp "$S/failed/bcawl0" "$T/rec.keep"; echo ENABLED > "$T/state-bcawl0"
check "  a retry that worked (ENABLED, record still there): one reload to clear it" "0 1" "$(at 1140)"
check "    the log names it" "yes" "$(grep -q 'supervision: recovered:bcawl0' "$T/log" && echo yes || echo no)"
echo DISABLED > "$T/state-bcawl0"; : > "$S/reprobe/last"
sed -i 's/^next=.*/next=1150/; s/^tries=.*/tries=1/' "$S/failed/bcawl0"
check "next=1150 at 1150 (39 s after the last reload): due" "0 1" "$(at 1150)"
sed -i 's/^next=.*/next=1160/' "$S/failed/bcawl0"
check "due at 1160 but the last reload was 1150 (< 20 s): none" "0 0" "$(at 1160)"
check "  then at 1170: one" "0 1" "$(at 1170)"
sed -i 's/^next=.*/next=/; s/^given_up=.*/given_up=1/; s/^tries=.*/tries=3/' "$S/failed/bcawl0"
check "given up: never again" "0 0|0 0" "$(at 2000)|$(at 9000)"
check "bcawl3 (ENABLED) never named by the supervision" "0" "$(grep -cE 'supervision: .*bcawl3|bcawl3: hostapd reports' "$T/log")"
# the hostapd process died
rm -rf "$S/failed"; echo ENABLED > "$T/state-bcawl0"
kill "$hapd_live" 2>/dev/null
sleep 0 & dead=$!; wait $dead
echo "$dead" > "$T/run/hostapd-wifi.pid"
check "hostapd died (its pid is gone): one reload" "0 1" "$(at 10000)"
check "  the log says so" "yes" "$(grep -q 'supervision: hostapd-died: reloading' "$T/log" && echo yes || echo no)"
check "still dead at 10030, 10060: reloads 2 and 3" "0 1|0 1" "$(at 10030)|$(at 10060)"
check "a 4th death within 600 s: none, said once" "0 0|0 0|1" "$(at 10090)|$(at 10120)|$(grep -c 'hostapd died 3 times in 10 min' "$T/log")"
check "600 s after the first death: reloads again" "0 1" "$(at 10601)"
sleep 1000 & alive=$!; echo "$alive" > "$T/run/hostapd-wifi.pid"
check "hostapd alive: nothing" "0 0" "$(at 11000)"
kill "$alive" 2>/dev/null
# a hostapd gone WITH its pid file (a clean exit removes it) while radios are applied
rm -f "$T/run/hostapd-wifi.pid"; rm -rf "$S/reprobe"
check "no pid file, radios applied: one reload" "0 1" "$(at 12000)"
rm -f "$S"/applied/*
check "no pid file, nothing applied (the service is driver-only): nothing" "0 0" "$(at 12100)"

# ---- img41: OWNERSHIP (header) ----
# hostapd dead, its netdevs present: due (as above); the same with a netdev
# absent (an unload or a re-probe under way): held, both kinds of reason
printf 'conf x\nfirst bcawl0\nradio k\n' > "$S/applied/bcawl0"; rm -rf "$S/reprobe"
echo "$dead" > "$T/run/hostapd-wifi.pid"; mkdir -p "$I"; echo 10 > "$I/bcawl0"; dev bcawl0 10
check "own control: hostapd dead, netdevs present: one reload" "0 1" "$(at 13000)"
rm -rf "$S/reprobe"; gone bcawl0
check "own: hostapd dead, bcawl0's netdev absent: held (no reload)" "0 0|0 0" "$(at 13100)|$(at 13150)"
dev bcawl0 20
check "own: bcawl0 back re-probed: still held while it settles, then ONE reload" "0 0|0 1" "$(at 13152)|$(at 13157)"
# the driver not loaded: no reload whatever is due, said once; loaded again: due again
rm -rf "$S/reprobe"; echo 10 > "$I/bcawl0"; dev bcawl0 10; : > "$T/log"; : > "$T/modules"
check "own: driver unloaded, hostapd dead: no reload, said once" "0 0|0 0|1" \
	"$(at 14000)|$(at 14100)|$(grep -c 'the Wi-Fi driver is not loaded: no reload' "$T/log")"
echo 'bca_pcie_ipc 4194304 0 - Live 0x0' > "$T/modules"
check "own control: driver loaded again: one reload" "0 1" "$(at 14200)"
rm -f "$S/applied/bcawl0"; rm -rf "$S/reprobe"; echo 10 > "$I/bcawl0"
# run: exits once its pid file no longer names it (the service stopped it,
# or started another); positive control: a pid file naming it keeps it
P="$T/run/gt-be98-wifi-reprobe.pid"
own_run() {	# own_run PASSES PIDFILE-CONTENT: rc + passes the run made (reloads unused)
	: > "$T/log"; rm -f "$P"
	GT_BE98_NOW=15000 GT_BE98_PASSES=$1 REPROBE_POLL=0 $SH -c 'case "$1" in self) echo $$ > "$0" ;; none) ;; *) echo "$1" > "$0" ;; esac; shift 2; exec "$@"' \
		"$P" "$2" x $SH "$R" run 2>/dev/null
	echo "$? $(grep -c 'exiting' "$T/log")"
}
check "own control: its own pid in the pid file: runs its 3 passes, no exit line" "0 0" "$(own_run 3 self)"
check "own: no pid file: exits at its first pass, said" "0 1" "$(own_run 1000 none)"
check "own: the pid file names another process: exits, said" "0 1" "$(own_run 1000 1)"

# ---- img40: the cost of a pass (header: COST) ----
# the carrier of a radio seen ENABLED is the event; hostapd is asked again after REPROBE_SAFETY s
rm -rf "$S/failed" "$S/reprobe"; for d in bcawl0 bcawl3; do printf 'conf x\nfirst %s\nradio k-%s\n' "$d" "$d" > "$S/applied/$d"; echo ENABLED > "$T/state-$d"; echo 1 > "$T/net/$d/carrier"; done
echo 10 > "$I/bcawl0" 2>/dev/null || { mkdir -p "$I"; echo 10 > "$I/bcawl0"; }; dev bcawl0 10; echo 1 > "$T/net/bcawl0/carrier"
sleep 1000 & alive=$!; echo "$alive" > "$T/run/hostapd-wifi.pid"
hc() { : > "$T/hcalls"; at "$1" > /dev/null; wc -l < "$T/hcalls" | tr -d ' '; }
check "cost: first pass asks hostapd for each radio" "2" "$(hc 20000)"
check "cost: ENABLED + carrier, 2 s later: hostapd not asked" "0" "$(hc 20002)"
check "cost: 29 s after: still not asked" "0" "$(hc 20029)"
check "cost: 30 s after (REPROBE_SAFETY): asked again" "2" "$(hc 20030)"
echo 0 > "$T/net/bcawl0/carrier"
check "cost: bcawl0 loses its carrier: bcawl0 asked at once, bcawl3 not" "1 bcawl0" "$(hc 20032) $(cat "$T/hcalls")"
echo DISABLED > "$T/state-bcawl0"
check "cost: no carrier, DISABLED at 20033: seen (not due yet)" "0 0" "$(at 20033)"
check "cost:   due at 20043 (REPROBE_DISABLED 10 s, as before)" "0 1" "$(at 20043)"
# DISABLED with the carrier still up: found by the safety ask, then the same 10 s wait
rm -rf "$S/reprobe"; echo ENABLED > "$T/state-bcawl0"; echo 1 > "$T/net/bcawl0/carrier"
at 30000 > /dev/null; echo DISABLED > "$T/state-bcawl0"
check "cost: DISABLED with carrier up at 30001..30029: not seen" "0 0|0 0" "$(at 30001)|$(at 30029)"
check "cost:   the safety ask at 30030 sees it (no reload yet)" "0 0 yes" "$(at 30030) $([ -f "$S/reprobe/bcawl0.dis" ] && echo yes)"
check "cost:   due 10 s later" "0 1" "$(at 30040)"
# a failure record: asked every pass whatever the carrier (as before)
rm -rf "$S/reprobe"; mkdir -p "$S/failed"; printf 'dev=bcawl0\nnext=\ngiven_up=0\n' > "$S/failed/bcawl0"; echo COUNTRY_UPDATE > "$T/state-bcawl0"
at 40000 > /dev/null
check "cost: a radio with a record is asked every pass" "1|1" "$(hc 40002 | head -1)|$(: > "$T/hcalls"; at 40004 > /dev/null; grep -c bcawl0 "$T/hcalls")"
rm -rf "$S/failed"
# no fork in the steady state: every external command the daemon runs is counted (PATH = counting wrappers only)
mkdir -p "$T/cnt"; : > "$T/execs"
for c in date cat sed awk head tr wc ls rm mkdir mkfifo sleep logger grep rc-service; do
	r=$(command -v "$c" 2>/dev/null) || continue
	printf '#!/bin/sh\necho %s >> "%s"\nexec %s "$@"\n' "$c" "$T/execs" "$r" > "$T/cnt/$c"
done
printf '#!/bin/sh\necho hostapd_cli >> "%s"\nexec %s "$@"\n' "$T/execs" "$T/bin/hostapd_cli" > "$T/cnt/hostapd_cli"
chmod +x "$T/cnt/"*
rm -rf "$S/reprobe"; echo ENABLED > "$T/state-bcawl0"; echo 1 > "$T/net/bcawl0/carrier"
for B in bash busybox; do
	command -v "$B" > /dev/null 2>&1 || { echo "skip $B (not installed)"; continue; }
	BS=$(command -v "$B"); [ "$B" = busybox ] && BS="$BS sh"
	ex() {	# ex PASSES: the external commands a run of that many steady passes started
		rm -rf "$S/reprobe"; : > "$T/execs"
		PATH="$T/cnt" GT_BE98_NOW=50000 GT_BE98_PASSES=$1 REPROBE_POLL=0 $BS -c 'echo $$ > "$0"; exec "$@"' "$T/run/gt-be98-wifi-reprobe.pid" $BS "$R" run 2> "$T/run.err"
		cp "$T/execs" "$T/execs.$1"; sort "$T/execs" | uniq -c | tr -s ' \n' ' '; echo "err=$(wc -c < "$T/run.err" | tr -d ' ')"
	}
	e1=$(ex 1); e21=$(ex 21)
	check "forks ($B): pass 1 asks hostapd once per radio" "2" "$(grep -c '^hostapd_cli$' "$T/execs.1")"
	check "forks ($B): 20 more steady passes run no external command" "$e1" "$e21"
	mv "$T/net/bcawl0/carrier" "$T/carrier.keep"; e1=$(ex 1); e21=$(ex 21); mv "$T/carrier.keep" "$T/net/bcawl0/carrier"
	check "forks ($B) control: bcawl0 without a carrier: 20 more hostapd_cli" "20" "$(( $(grep -c '^hostapd_cli$' "$T/execs.21") - $(grep -c '^hostapd_cli$' "$T/execs.1") ))"
	if ST=$(command -v strace 2>/dev/null); then
		sf() {	# sf PASSES: the forks of a run of that many steady passes
			rm -rf "$S/reprobe"
			PATH="$T/cnt" GT_BE98_NOW=50000 GT_BE98_PASSES=$1 REPROBE_POLL=0 $ST -f -qq -e trace=clone,clone3,fork,vfork -o "$T/st" $BS -c 'echo $$ > "$0"; exec "$@"' "$T/run/gt-be98-wifi-reprobe.pid" $BS "$R" run 2>/dev/null
			grep -cE '^[0-9]+ +(clone|clone3|fork|vfork)\(' "$T/st"
		}
		f1=$(sf 1); f21=$(sf 21)
		check "forks ($B, strace): 20 more steady passes fork nothing" "0" "$((f21 - f1))"
		mv "$T/net/bcawl0/carrier" "$T/carrier.keep"
		f1=$(sf 1); f21=$(sf 21)
		check "forks ($B, strace) control: bcawl0 without a carrier is asked every pass (>= 20 forks more)" "yes" "$([ $((f21 - f1)) -ge 20 ] && echo yes || echo "no ($((f21 - f1)))")"
		mv "$T/carrier.keep" "$T/net/bcawl0/carrier"
	fi
done
kill "$alive" 2>/dev/null

if [ $fail = 0 ]; then echo "ALL OK ($n checks)"; else echo "FAILED"; cat "$T/log"; fi
exit $fail

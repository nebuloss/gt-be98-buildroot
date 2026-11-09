#!/bin/sh
# shellcheck shell=busybox
# The service is sourced: its functions and the settings below are used by it.
# shellcheck disable=SC2034,SC2329
# SPDX-License-Identifier: GPL-2.0
# Offline test of the hostapd part of init.d/gt-be98-wifi (no device, no
# root): sh test/gt-be98-wifi-service-test.sh
# hostapd is a fake that keeps, like hostapd 2.12, a list of radio ifaces
# each with its BSSes, and answers the global control commands the service
# uses with hostapd's semantics (src/ap/hostapd.c):
#   ADD bss_config=<phy>:<file>  phy not served: a new iface with every
#        interface=/bss= of the file; phy served: the file must hold ONE BSS,
#        appended to that iface (hostapd_interface_init_bss)
#   REMOVE <ifname>  the first BSS of an iface: the whole iface; another BSS:
#        that BSS only (hostapd_remove_iface / hostapd_remove_bss)
#   INTERFACES, PING
# The bridge/VLAN functions are stubbed (they need a kernel); the checks are
# on the commands the service sends.
set -u
here=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d)
trap 'for f in $(find "$T" -name "*.pid"); do kill "$(cat "$f")" 2>/dev/null; done; rm -rf "$T"' EXIT
export GT_BE98_RUN="$T/run" GT_BE98_SYSNET="$T/net" GT_BE98_HAP_LOG="$T/hostapd.log" \
	GT_BE98_WIFI_GEN="$here/../src/sbin/gt-be98-wifi-gen" FAKE="$T" \
	GT_BE98_WIFI_STA="$T/bin/gt-be98-wifi-sta"
mkdir -p "$T/bin" "$T/run"
for p in 0:a4 1:a8 2:ac 3:a0; do	# bcawl<i>: phy<i>, address
	mkdir -p "$T/net/bcawl${p%%:*}/phy80211"
	echo "phy${p%%:*}" > "$T/net/bcawl${p%%:*}/phy80211/name"
	echo "00:00:5e:00:53:${p#*:}" > "$T/net/bcawl${p%%:*}/address"
done
cat > "$T/bin/hostapd_cli" <<'X'
#!/bin/sh
# hostapd_cli -p DIR -i NAME raw CMD [ARG] (global) | -i NAME status (a BSS)
ifn=
while [ $# -gt 0 ]; do case $1 in -i) ifn=$2; shift 2 ;; -p) shift 2 ;; raw) shift; break ;; *) break ;; esac; done
S=$FAKE/hapd
p=$(cat "$FAKE/run/hostapd-wifi.pid" 2>/dev/null)
[ -n "$p" ] && kill -0 "$p" 2>/dev/null || { echo "Failed to connect to hostapd"; exit 255; }
touch "$S"
# a BSS's status: its state, $FAKE/state-<ifname> (a radio that fails late:
# DISABLED), else ENABLED while hostapd runs it
if [ "${1:-}" = status ]; then
	tr ' ' '\n' < "$S" | grep -qx "$ifn" || exit 1
	echo "state=$(cat "$FAKE/state-$ifn" 2>/dev/null || echo ENABLED)"; exit 0
fi
case "$1" in PING|INTERFACES) ;; *) echo "$*" >> "$FAKE/cmds"; echo "hapd $*" >> "$FAKE/seq" ;; esac
if [ -f "$FAKE/fail" ] && echo "$*" | grep -q -f "$FAKE/fail"; then echo FAIL; exit 0; fi
inuse() { tr ' ' '\n' < "$S" | grep -qx "$1"; }
case "$1" in
PING) echo PONG ;;
INTERFACES) awk '{ for (i = 2; i <= NF; i++) print $i }' "$S" ;;
ADD)	a=${2#bss_config=}; phy=${a%%:*}; f=${a#*:}
	[ -f "$f" ] || { echo FAIL; exit 0; }
	names=$(sed -n 's/^\(interface\|bss\)=//p' "$f")
	for n in $names; do inuse "$n" && { echo FAIL; exit 0; }; done
	if grep -q "^$phy " "$S"; then
		[ "$(echo $names | wc -w)" = 1 ] || { echo FAIL; exit 0; }
		sed -i "s/^$phy .*/& $names/" "$S"
	else
		echo "$phy" $names >> "$S"
	fi
	echo OK ;;
REMOVE)	if grep -q "^[^ ]* $2\( \|\$\)" "$S"; then sed -i "/^[^ ]* $2\( \|\$\)/d" "$S"; echo OK
	elif inuse "$2"; then sed -i "s/ $2\( \|\$\)/\1/" "$S"; echo OK
	else echo FAIL; fi ;;
*) echo FAIL ;;
esac
X
cat > "$T/bin/ssd" <<'X'
#!/bin/sh
case " $* " in
*" --start "*)	pf=; while [ $# -gt 0 ]; do [ "$1" = --pidfile ] && pf=$2; [ "$1" = -- ] && { shift; break; }; shift; done
	sleep 1000 & echo $! > "$pf"
	case "$pf" in *hostapd*) rm -f "$FAKE/hapd"; echo "start $*" >> "$FAKE/daemon" ;; *) echo "start $pf" >> "$FAKE/stalog" ;; esac ;;
*" --stop "*)	pf=; while [ $# -gt 0 ]; do [ "$1" = --pidfile ] && pf=$2; shift; done
	kill "$(cat "$pf")" 2>/dev/null
	case "$pf" in *hostapd*) rm -f "$FAKE/hapd"; echo stop >> "$FAKE/daemon" ;; *) echo "stop $pf" >> "$FAKE/stalog" ;; esac ;;
esac
exit 0
X
# iw: "phy <phy> info" prints $FAKE/iw-<phy> when present (the interface
# combination), nothing otherwise; a monitor add/del creates/removes its
# netdev (logged to $FAKE/iwlog with every set freq); the rest succeeds
cat > "$T/bin/iw" <<'X'
#!/bin/sh
[ "$1" = phy ] && [ "$3" = info ] && [ -f "$FAKE/iw-$2" ] && cat "$FAKE/iw-$2"
case "$*" in
"phy "*" interface add "*" type monitor") mkdir -p "$FAKE/net/$5"; echo "$*" >> "$FAKE/iwlog" ;;
"dev "*" del") rm -rf "${FAKE:?}/net/$2"; echo "$*" >> "$FAKE/iwlog" ;;
"dev "*" interface add "*" type __ap") mkdir -p "$FAKE/net/$5"; echo "$*" >> "$FAKE/iwlog"; echo "iw add $5" >> "$FAKE/seq" ;;
"dev "*" set freq "*) echo "$*" >> "$FAKE/iwlog" ;;
esac
exit 0
X
# ip: logs "link set dev X up|down" (the monitor path); succeeds
cat > "$T/bin/ip" <<'X'
#!/bin/sh
echo "$*" >> "$FAKE/iplog"
exit 0
X
# gt-be98-wifi-sta: logs its calls to $FAKE/stalog; freq DEV answers
# $FAKE/freq-DEV (absent: not associated); "up" of a station makes it
# associate at $FAKE/assoc-DEV when that file exists
cat > "$T/bin/gt-be98-wifi-sta" <<'X'
#!/bin/sh
case "$1" in
freq) [ -f "$FAKE/freq-$2" ] && cat "$FAKE/freq-$2" && exit 0; exit 1 ;;
up) [ -f "$FAKE/assoc-$2" ] && cp "$FAKE/assoc-$2" "$FAKE/freq-$2"; echo "$*" >> "$FAKE/stalog"; echo "sta up $2${5:+ $5}" >> "$FAKE/seq" ;;
down) rm -f "$FAKE/freq-$2"; echo "$*" >> "$FAKE/stalog"; echo "sta down $2" >> "$FAKE/seq" ;;
route|unroute) echo "$1 $(cat "$FAKE/run/gt-be98-wifi/routed" 2>/dev/null | tr '\n' ',')" >> "$FAKE/stalog" ;;
*) echo "$*" >> "$FAKE/stalog" ;;
esac
exit 0
X
chmod +x "$T/bin/"*
PATH="$T/bin:$PATH"

cp "$T/bin/ssd" "$T/bin/start-stop-daemon"
# busybox sh runs its own start-stop-daemon applet before PATH: a function
# wins over it (dash refuses such a name, and uses PATH)
if (eval 'a-b() { :; }') 2>/dev/null; then
	eval 'start-stop-daemon() { "$T/bin/ssd" "$@"; }'
fi
# OpenRC helpers, then the service itself
ebegin() { :; }; eend() { return "${1:-0}"; }
einfo() { echo "  * $*" >> "$T/out"; }; ewarn() { echo "  ! $*" >> "$T/out"; }
eerror() { echo "  E $*" >> "$T/out"; }
# shellcheck disable=SC1091
. "$here/../src/init.d/gt-be98-wifi"
# busybox sh runs its ip applet before PATH: the fake as a function
ip() { "$T/bin/ip" "$@"; }
br_create() { echo "$1" >> "$T/brlog"; return 0; }; vlan_attach() { return 0; }
vlan_prune() { :; }; br_prune() { :; }; isolate_ports() { :; }
ap_override() { :; }	# no web UI file: the settings below

WIFI_NETWORKS="$T/nets" WIFI_SLOTS="$T/slots" WIFI_MAX_BSS=4 HOSTAPD_CONFS=''
WIFI_BRIDGES='' WIFI_VLANS='' WIFI_ISOLATE='' WIFI_TRUNK=rnr0 HOSTAPD_ARGS=''
HOSTAPD_GLOBAL="$T/run/hostapd-global" HOSTAPD_CTRL="$T/run/hostapd" IFACE_WAIT=1 REGDB_OK=0
G="$T/run/gt-be98-wifi/gen"
fail=0 n=0
check() {
	n=$((n + 1))
	if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want [$2] got [$3]"; fail=1; fi
}
apply() {	# run apply_hostapd; $cmds = the commands it sent
	: > "$T/cmds"; : > "$T/out"
	# a subshell: what apply_hostapd adds to WIFI_* does not leak
	( apply_hostapd ) >> "$T/out" 2>&1
	rc=$?
	cmds=$(cat "$T/cmds")
}
hapd() { cat "$T/hapd" 2>/dev/null; }
net() { printf 'network=%s\nssid=%s\nsecurity=%s\npassphrase=%s\nbands=%s\nvlan=%s\n' "$@"; }
three() {
	printf 'network=30\nssid=guest\nsecurity=open-owe\nbands=2g 5gl 5gh 6g\nvlan=30\nisolate=1\n'
	net 10 home psk2sae "correct horse battery" "2g 5gl 5gh" 10
	net 20 iot psk2 "${IOTPASS:-iotpass123}" 2g 20
}

# 1. first start: one process, the four radios added whole
three > "$T/nets"
apply
check "start: rc" 0 $rc
check "start: one process, global socket only" "start -B -P $T/run/hostapd-wifi.pid -t -f $T/hostapd.log -g $T/run/hostapd-global" "$(cat "$T/daemon")"
check "start: each radio added whole" "ADD bss_config=phy3:$G/hostapd-bcawl3.conf
ADD bss_config=phy0:$G/hostapd-bcawl0.conf
ADD bss_config=phy1:$G/hostapd-bcawl1.conf
ADD bss_config=phy2:$G/hostapd-bcawl2.conf" "$cmds"
check "start: hostapd runs" "phy3 bcawl3 bcawl3-1 bcawl3-2
phy0 bcawl0 bcawl0-1
phy1 bcawl1 bcawl1-1
phy2 bcawl2" "$(hapd)"
check "start: netguard file" 'WIFI_TRUNK="rnr0" WIFI_VLANS="brwifi30:30 brwifi10:10 brwifi20:20" WIFI_ISOLATE="brwifi30"' \
	"$(grep -v '^#' "$T/run/gt-be98-wifi/l2.conf" | tr '\n' ' ' | sed 's/ $//')"

# 2. nothing changed: nothing sent
apply
check "unchanged: no command" "" "$cmds"

# 3. a further BSS changes (iot passphrase): that BSS only
IOTPASS=iot-new-pass three > "$T/nets"
apply
check "iot re-keyed: only bcawl3-2 re-added" "REMOVE bcawl3-2
ADD bss_config=phy3:$G/bss-bcawl3-2.conf" "$cmds"
check "iot re-keyed: others untouched" "phy3 bcawl3 bcawl3-1 bcawl3-2
phy0 bcawl0 bcawl0-1
phy1 bcawl1 bcawl1-1
phy2 bcawl2" "$(hapd)"

# 4. a network added on 5gl: one ADD
{ IOTPASS=iot-new-pass three; net 40 cam sae camera-pass 5gl 40; } > "$T/nets"
apply
check "cam added: one BSS" "ADD bss_config=phy0:$G/bss-bcawl0-2.conf" "$cmds"

# 5. a network removed (home, on three radios): three REMOVEs, nothing else
{ IOTPASS=iot-new-pass three | awk '/^network=10$/ { s = 1; next } /^network=/ { s = 0 } !s'
  net 40 cam sae camera-pass 5gl 40; } > "$T/nets"
apply
check "home removed: its three BSSes only" "REMOVE bcawl3-1
REMOVE bcawl0-1
REMOVE bcawl1-1" "$cmds"
check "home removed: iot and cam keep their netdevs" "phy3 bcawl3 bcawl3-2
phy0 bcawl0 bcawl0-2
phy1 bcawl1
phy2 bcawl2" "$(hapd)"

# 6. the anchor (guest) changes: every radio it is on restarts
sed -i 's/^ssid=guest$/ssid=guest2/' "$T/nets"
apply
check "anchor changed: radio restarts" "REMOVE bcawl3
ADD bss_config=phy3:$G/hostapd-bcawl3.conf
REMOVE bcawl0
ADD bss_config=phy0:$G/hostapd-bcawl0.conf
REMOVE bcawl1
ADD bss_config=phy1:$G/hostapd-bcawl1.conf
REMOVE bcawl2
ADD bss_config=phy2:$G/hostapd-bcawl2.conf" "$cmds"

# 7. a radio-wide line (5gl channel): that radio only
{ printf 'radio=5gl\nchannel=44\n'; cat "$T/nets"; } > "$T/nets.new"; mv "$T/nets.new" "$T/nets"
apply
check "5gl channel: 5gl restarts alone" "REMOVE bcawl0
ADD bss_config=phy0:$G/hostapd-bcawl0.conf" "$cmds"

# 8. hostapd lost a BSS: added again
sed -i 's/ bcawl3-2//' "$T/hapd"
apply
check "lost BSS: added again" "ADD bss_config=phy3:$G/bss-bcawl3-2.conf" "$cmds"

# 9. a per-BSS ADD fails: the radio is restarted
{ cat "$T/nets"; net 50 cam2 sae camera-pass2 2g 50; } > "$T/nets.new"; mv "$T/nets.new" "$T/nets"
echo 'bss-bcawl3-1' > "$T/fail"
apply
rm -f "$T/fail"
check "failed BSS add: radio restart" "ADD bss_config=phy3:$G/bss-bcawl3-1.conf
REMOVE bcawl3
ADD bss_config=phy3:$G/hostapd-bcawl3.conf" "$cmds"
check "failed BSS add: radio complete" "phy3 bcawl3 bcawl3-1 bcawl3-2" "$(hapd | grep '^phy3')"

# 10. a refused list (a list-wide error): nothing sent, everything left as it was
cp "$T/nets" "$T/nets.ok"; before=$(hapd)
printf 'radio=2g\nchannel=999\n' >> "$T/nets"
apply
check "refused list: rc 1, no command, hostapd as before" "1 - same" "$rc -$cmds $( [ "$(hapd)" = "$before" ] && echo same || echo changed)"
cp "$T/nets.ok" "$T/nets"
# 10b. one bad network (WPA2 on 6 GHz) is skipped, not the list: rc 0,
# nothing sent (the other networks did not change), the skip reported
# (run 1105-0223/0227: one network that cannot run must not take the
# radios down)
net 60 bad psk2 password6 6g 60 >> "$T/nets"
apply
check "bad network: rc 0, no command, hostapd as before" "0 - same" "$rc -$cmds $( [ "$(hapd)" = "$before" ] && echo same || echo changed)"
check "bad network: skipped, reported" "skipped 60|yes" \
	"$(grep '^skipped ' "$G/plan")|$(grep -q '! Wi-Fi network(s) 60 skipped' "$T/out" && echo yes || echo no)"
cp "$T/nets.ok" "$T/nets"
apply
check "bad network removed: no skipped line" "0 0" "$rc $(grep -c '^skipped ' "$G/plan")"

# 11. HOSTAPD_ARGS changed: the process restarts, every radio is added again
: > "$T/daemon"
HOSTAPD_ARGS=-d
apply
check "HOSTAPD_ARGS: process restarted" "stop
start -B -P $T/run/hostapd-wifi.pid -t -f $T/hostapd.log -g $T/run/hostapd-global -d" "$(cat "$T/daemon")"
check "HOSTAPD_ARGS: 4 radios added" 4 "$(echo "$cmds" | grep -c '^ADD bss_config=phy[0-3]:.*/hostapd-bcawl')"
HOSTAPD_ARGS=
apply

# 12. a ready-made config on another radio, beside the networks
awk '/^network=/ { n = $0 } !(n == "network=30" && /^bands=/) { print; next } { print "bands=2g 5gl 5gh" }' "$T/nets" > "$T/nets.new"
mv "$T/nets.new" "$T/nets"	# guest leaves 6g: bcawl2 is free
cat > "$T/legacy.conf" <<'EOF'
interface=bcawl2
driver=nl80211
hw_mode=a
op_class=131
channel=37
ssid=x
EOF
HOSTAPD_CONFS="$T/legacy.conf"
apply
check "ready-made config: bcawl2 from it" "REMOVE bcawl2
ADD bss_config=phy2:$T/legacy.conf" "$cmds"
echo "ieee80211ax=1" >> "$T/legacy.conf"
apply
check "ready-made config changed: its radio restarts" "REMOVE bcawl2
ADD bss_config=phy2:$T/legacy.conf" "$cmds"
sed -i 's/^bands=2g 5gl 5gh$/bands=2g 5gl 5gh 6g/' "$T/nets"
apply
check "radio in both sources: refused (rc 1)" "1" "$rc"
check "radio in both sources: said so" "yes" "$(grep -q 'already configured' "$T/out" && echo yes || echo no)"
HOSTAPD_CONFS=

# 13. nothing configured: the process stops
: > "$T/nets"
apply
check "no network: hostapd stopped" "stop" "$(tail -n1 "$T/daemon")"
check "no network: no state left" "" "$(ls "$T/run/gt-be98-wifi/applied" 2>/dev/null)"
check "no network: no error" "0 " "$rc $(grep -E ' E |cannot' "$T/out")"

# 14. the BSS cap per radio: WIFI_MAX_BSS, else what the driver advertises
combo() {	# combo PHY N: iw phy PHY info, as iw 6.17 prints a combination
	printf '\tvalid interface combinations:\n\t\t * #{ AP } <= %s,\n\t\t   total <= %s, #channels <= 1\n' "$2" "$2" > "$T/iw-$1"
}
cap() { : > "$T/out"; wifi_max_bss; echo "$MAX_BSS $(cat "$T/run/gt-be98-wifi/max-bss") $(grep -c ' ! ' "$T/out")"; }
check "cap: no iw combination, unset: 4" "4 4 0" "$(WIFI_MAX_BSS=; cap)"
for p in 0 1 2 3; do combo phy$p 8; done
check "cap: driver advertises 8, unset: 8" "8 8 0" "$(WIFI_MAX_BSS=; cap)"
combo phy1 4
check "cap: the smallest radio wins" "4 4 0" "$(WIFI_MAX_BSS=; cap)"
combo phy1 8
check "cap: WIFI_MAX_BSS=3 kept" "3 3 0" "$(WIFI_MAX_BSS=3; cap)"
check "cap: WIFI_MAX_BSS=12 above the driver's: 8, warned" "8 8 1" "$(WIFI_MAX_BSS=12; cap)"
check "cap: WIFI_MAX_BSS=x: the driver's, warned" "8 8 1" "$(WIFI_MAX_BSS=x; cap)"
for p in 0 1 2 3; do combo phy$p 16; done
check "cap: never above 8 (the BSSID rule)" "8 8 0" "$(WIFI_MAX_BSS=; cap)"
rm -f "$T"/iw-phy*
# the generator gets it: 5 networks on 2.4 GHz pass at 8, are refused at 4
for p in 0 1 2 3; do combo phy$p 8; done
for i in 1 2 3 4 5; do net $((60 + i)) "m$i" sae "password$i" 2g $((60 + i)); done > "$T/nets"
WIFI_MAX_BSS=; apply
check "5 networks on one radio, driver cap 8: rc 0, 5 BSSes" "0 5" "$rc $(awk '$1 == "bss" && $2 == "bcawl3"' "$G/plan" | wc -l | tr -d ' ')"
rm -f "$T"/iw-phy*
apply
check "5 networks on one radio, no cap advertised (4): refused" "1" "$rc"
: > "$T/nets"; apply; WIFI_MAX_BSS=4

# 15. schedules: the list is rendered at the time gt-be98-wifi-sched gives;
# a network leaving/entering its window is one BSS removed/added
WIFI_SCHED="$T/bin/fake-sched"
printf '#!/bin/sh\n[ "$1" = now ] && [ -f "$FAKE/now" ] && cat "$FAKE/now" && exit 0\nexit 1\n' > "$WIFI_SCHED"
chmod +x "$WIFI_SCHED"
{ net 1 always sae password1 2g 1; net 2 office sae password2 2g 2; printf 'schedule=weekdays@08:00-18:00\n'; } > "$T/nets"
rm -f "$T/slots"
echo '1 09:00' > "$T/now"; apply
check "schedule, Mon 09:00: both BSSes" "0 phy3 bcawl3 bcawl3-1 net 2 on" "$rc $(hapd) $(cat "$G/sched")"
echo '6 09:00' > "$T/now"; apply
check "schedule, Sat 09:00: office's BSS removed alone" "0 REMOVE bcawl3-1 phy3 bcawl3 net 2 off" "$rc $cmds $(hapd) $(cat "$G/sched")"
check "schedule, Sat: office's slot kept" "2g 1 2 1" "$(grep '^2g 1 ' "$T/slots")"
echo '1 08:00' > "$T/now"; apply
check "schedule, Mon 08:00: office's BSS added back alone" "0 ADD bss_config=phy3:$G/bss-bcawl3-1.conf" "$rc $cmds"
rm -f "$T/now"; echo '6 09:00' > "$T/now.x"; apply
check "schedule, clock not synchronised: every network runs, warned" "0 - net 2 on yes" \
	"$rc -$cmds $(cat "$G/sched") $(grep -q 'schedules are not applied' "$T/out" && echo yes || echo no)"
: > "$T/nets"; apply; WIFI_SCHED=/nonexistent

# 16. a monitor radio: hostapd releases it, its primary goes down, <dev>mon
# is created and tuned; back to AP: the monitor goes first, then the radio
WIFI_MAX_BSS=4
{ net 1 a sae password1 "2g 5gh" 1; } > "$T/nets"
rm -f "$T/slots" "$T/iwlog" "$T/iplog"; apply
check "monitor control: 2g and 5gh run" "0 phy3 bcawl3 phy1 bcawl1" "$rc $(hapd | tr '\n' ' ' | sed 's/ $//')"
{ printf 'radio=5gh\nmonitor=1\nchannel=149\nwidth=80\n'; net 1 a sae password1 "2g 5gh" 1; } > "$T/nets"
: > "$T/iplog"; apply
check "monitor=1: bcawl1 removed from hostapd, nothing else" "0 REMOVE bcawl1 phy3 bcawl3" "$rc $cmds $(hapd)"
check "monitor=1: primary down, then bcawl1mon created, up, tuned 5745/80/5775" \
	"link set dev bcawl1 down|link set dev bcawl1mon up|phy phy1 interface add bcawl1mon type monitor|dev bcawl1mon set freq 5745 80 5775" \
	"$(grep -E 'bcawl1' "$T/iplog" | tr '\n' '|')$(tr '\n' '|' < "$T/iwlog" | sed 's/|$//')"
check "monitor=1: owned, netdev present" "bcawl1mon yes" "$(cat "$T/run/gt-be98-wifi/monitors") $([ -d "$T/net/bcawl1mon" ] && echo yes || echo no)"
: > "$T/iwlog"; apply
check "monitor unchanged: no hostapd command, re-tuned only" "- dev bcawl1mon set freq 5745 80 5775" "-$cmds $(cat "$T/iwlog")"
{ printf 'radio=5gh\nmonitor=1\nchannel=36\nwidth=20\n'; net 1 a sae password1 "2g 5gh" 1; } > "$T/nets"
apply
check "a 5gh channel 5gh does not have: refused, the monitor kept" "1 yes" "$rc $([ -d "$T/net/bcawl1mon" ] && echo yes || echo no)"
{ printf 'radio=5gh\nmonitor=1\nchannel=100\nwidth=20\n'; net 1 a sae password1 "2g 5gh" 1; } > "$T/nets"
: > "$T/iwlog"; apply
check "monitor on 100/20: HT20 form" "dev bcawl1mon set freq 5500 HT20" "$(cat "$T/iwlog")"
{ net 1 a sae password1 "2g 5gh" 1; } > "$T/nets"
: > "$T/iwlog"; apply
check "monitor off: deleted, then bcawl1 back in hostapd" "0 dev bcawl1mon del ADD bss_config=phy1:$G/hostapd-bcawl1.conf no" \
	"$rc $(cat "$T/iwlog") $cmds $([ -d "$T/net/bcawl1mon" ] && echo yes || echo no)"
check "monitor off: none owned" "" "$(cat "$T/run/gt-be98-wifi/monitors")"
# LEDs: led=0 -> $STATE/leds for gt-be98-leds
{ printf 'radio=2g\nled=0\nradio=6g\nled=0\n'; net 1 a sae password1 "2g 5gh" 1; } > "$T/nets"
apply
check "led=0 on 2g and 6g: WIFI_LEDS_OFF in band order" 'WIFI_LEDS_OFF="bcawl3 bcawl2"' "$(grep -v '^#' "$T/run/gt-be98-wifi/leds")"
{ net 1 a sae password1 "2g 5gh" 1; } > "$T/nets"; apply
check "led default: none off" 'WIFI_LEDS_OFF=""' "$(grep -v '^#' "$T/run/gt-be98-wifi/leds")"
# a monitor alone (no BSS anywhere): the process stops, the monitor is made
{ printf 'radio=5gl\nmonitor=1\n'; printf 'radio=2g\nmonitor=1\n'; net 1 a sae password1 "2g 5gl" 1; } > "$T/nets"
: > "$T/iwlog"; apply
check "monitors only: hostapd stopped, two monitors" "0 stop 2" "$rc $(tail -n1 "$T/daemon") $(grep -c 'type monitor' "$T/iwlog")"
( stop_hostapd ) >> "$T/out" 2>&1
check "stop: monitors deleted, leds file gone" "0 no" "$(grep -c . "$T/run/gt-be98-wifi/monitors") $([ -f "$T/run/gt-be98-wifi/leds" ] && echo yes || echo no)"
: > "$T/nets"; apply

# 17. a station (Wi-Fi uplink) on 5gl beside a network on 2g and 5gl
WIFI_MAX_BSS=4
rm -f "$T/slots" "$T/iwlog" "$T/stalog" "$T/seq" "$T"/freq-* "$T"/assoc-*
sta() { printf 'station=5gl\nenabled=%s\nssid=uplink\nsecurity=psk2\npassphrase=uplinkpass1\n' "${1:-1}"; }
{ printf 'radio=5gl\nchannel=36\nwidth=80\n'; net 1 a sae password1 "2g 5gl" 1; } > "$T/nets"
apply
check "station control: the network on bcawl3 and bcawl0" "0 phy3 bcawl3 phy0 bcawl0" "$rc $(hapd | tr '\n' ' ' | sed 's/ $//')"
: > "$T/seq"; echo 5200 > "$T/assoc-bcawl0"
{ printf 'radio=5gl\nchannel=36\nwidth=80\n'; sta; net 1 a sae password1 "2g 5gl" 1; } > "$T/nets"
apply
check "station added: hostapd releases bcawl0, the AP interface, the station, then the APs (A1 order)" \
	"0 hapd REMOVE bcawl0|iw add bcawl0-1|sta up bcawl0 restart|hapd ADD bss_config=phy0:$G/hostapd-bcawl0.conf" \
	"$rc $(tr '\n' '|' < "$T/seq" | sed 's/|$//')"
check "station added: the network on the virtual interface, channel 40 (the uplink's 5200 MHz), 80 MHz kept" \
	"phy3 bcawl3 phy0 bcawl0-1 interface=bcawl0-1 channel=40 vht_oper_centr_freq_seg0_idx=42" \
	"$(hapd | tr '\n' ' ')$(grep -E '^(interface|channel|vht_oper_centr_freq_seg0_idx)=' "$G/hostapd-bcawl0.conf" | tr '\n' ' ' | sed 's/ $//')"
check "station added: unit first, stations, vifs, the monitor started" \
	"first bcawl0-1|bcawl0|bcawl0-1|start $T/run/gt-be98-wifi-sta.pid" \
	"$(grep '^first' "$T/run/gt-be98-wifi/applied/bcawl0")|$(cat "$T/run/gt-be98-wifi/stations")|$(cat "$T/run/gt-be98-wifi/vifs")|$(grep "^start" "$T/stalog")"
check "station added: the station config is 0600, its passphrase quoted" "-rw------- 1" \
	"$(ls -l "$G/sta-bcawl0.conf" | cut -c1-10) $(grep -c '^	psk="uplinkpass1"$' "$G/sta-bcawl0.conf")"
: > "$T/seq"; apply
check "station unchanged: no hostapd command, the station kept (up, same config)" "0 - sta up bcawl0" "$rc -$cmds $(tr '\n' '|' < "$T/seq" | sed 's/|$//')"
# the uplink moved the radio: the APs follow (radio restart on channel 36)
rm -f "$T/assoc-bcawl0"; echo 5180 > "$T/freq-bcawl0"; : > "$T/seq"; apply
check "uplink on 5180 MHz: the radio restarts on channel 36" \
	"0 sta up bcawl0|hapd REMOVE bcawl0-1|hapd ADD bss_config=phy0:$G/hostapd-bcawl0.conf channel=36" \
	"$rc $(tr '\n' '|' < "$T/seq" | sed 's/|$//') $(grep '^channel=' "$G/hostapd-bcawl0.conf")"
# routed network behind the station
{ printf 'radio=5gl\nchannel=36\nwidth=80\n'; sta; net 1 a sae password1 "2g 5gl" 1
  printf 'network=50\nssid=rep\nsecurity=sae\npassphrase=password5\nbands=5gl\nrouted=192.168.50.1/24\n'; } > "$T/nets"
: > "$T/stalog"; apply
check "routed network: its BSS on bcawl0-2, the routed list, route applied" \
	"0 phy3 bcawl3 phy0 bcawl0-1 bcawl0-2 brwifi50 192.168.50.1/24 route brwifi50 192.168.50.1/24," \
	"$rc $(hapd | tr '\n' ' ')$(cat "$T/run/gt-be98-wifi/routed") $(grep '^route' "$T/stalog")"
check "routed network: no VLAN for its bridge (l2.conf)" "no" "$(grep -q 'brwifi50:' "$T/run/gt-be98-wifi/l2.conf" && echo yes || echo no)"
# repeater: the station 4-address, the repeated network bridged to it (no VLAN, no route)
{ printf 'radio=5gl\nchannel=36\nwidth=80\n'; sta; printf 'repeater=multiap\n'; net 1 a sae password1 "2g 5gl" 1
  printf 'network=60\nssid=rpt\nsecurity=sae\npassphrase=password6\nbands=5gl\nrepeated=1\nisolate=1\n'; } > "$T/nets"
: > "$T/stalog"; : > "$T/brlog"; apply
check "repeated network: its bridge created, the repeaters list, nothing routed" \
	"0 yes bcawl0 brwifi60|" \
	"$rc $(grep -qx brwifi60 "$T/brlog" && echo yes || echo no) $(cat "$T/run/gt-be98-wifi/repeaters")|$(cat "$T/run/gt-be98-wifi/routed")"
check "repeated network: no VLAN for its bridge, isolated (l2.conf)" "no yes" \
	"$(grep -q 'brwifi60:' "$T/run/gt-be98-wifi/l2.conf" && echo yes || echo no) $(grep -q '^WIFI_ISOLATE=".*brwifi60' "$T/run/gt-be98-wifi/l2.conf" && echo yes || echo no)"
# control: the same station without repeater= has no repeaters line (the network refused: no 4-address uplink)
{ printf 'radio=5gl\nchannel=36\nwidth=80\n'; sta; net 1 a sae password1 "2g 5gl" 1; } > "$T/nets"
apply
check "control: no repeater, the repeaters list empty" "0 " "$rc $(cat "$T/run/gt-be98-wifi/repeaters")"
# station off: the APs leave the virtual interfaces first, the station goes,
# the radio netdev is an AP again, the virtual interface is deleted
{ printf 'radio=5gl\nchannel=36\nwidth=80\n'; sta 0; net 1 a sae password1 "2g 5gl" 1; } > "$T/nets"
: > "$T/seq"; : > "$T/iwlog"; : > "$T/stalog"; apply
check "station off: REMOVE the radio, station down, ADD on bcawl0, vif deleted, monitor stopped" \
	"0 hapd REMOVE bcawl0-1|sta down bcawl0|hapd ADD bss_config=phy0:$G/hostapd-bcawl0.conf dev bcawl0-1 del phy3 bcawl3 phy0 bcawl0 stop $T/run/gt-be98-wifi-sta.pid" \
	"$rc $(tr '\n' '|' < "$T/seq" | sed 's/|$//') $(cat "$T/iwlog") $(hapd | tr '\n' ' ')$(grep '^stop' "$T/stalog")"
check "station off: no station, no vif" "|" "$(cat "$T/run/gt-be98-wifi/stations")|$(cat "$T/run/gt-be98-wifi/vifs")"
# a station alone (no network on any radio): no hostapd, the station runs
{ sta; } > "$T/nets"; : > "$T/seq"; apply
check "station only: hostapd stopped, the station up" "0 stop sta up bcawl0" "$rc $(tail -n1 "$T/daemon") $(tr '\n' '|' < "$T/seq" | grep -o 'sta up bcawl0')"
( stop_hostapd ) >> "$T/out" 2>&1
check "stop: the station down, routing undone" "down bcawl0 unroute" "$(grep -E '^(down|unroute)' "$T/stalog" | tail -n2 | cut -d' ' -f1,2 | tr '\n' ' ' | sed 's/ *$//')"
: > "$T/nets"; apply

# 18. beacon protection: the radios whose driver advertises it (iw phy info
# "[ BEACON_PROTECTION ]", open-wifi SD-BCNPROT) get beacon_prot=1 on their
# SAE/OWE BSSes; the _CLIENT feature alone is not it
rm -f "$T/slots" "$T"/iw-phy*
{ net 1 a sae password1 "2g 5gl" 1; net 2 b psk2 password2 2g 2; } > "$T/nets"
apply
check "no radio advertises it: rc 0, no beacon_prot" "0 0" "$rc $(cat "$G"/hostapd-*.conf | grep -c '^beacon_prot=1$')"
printf '\tSupported extended features:\n\t\t* [ BEACON_PROTECTION ]: beacon protection support\n' > "$T/iw-phy3"
printf '\tSupported extended features:\n\t\t* [ BEACON_PROTECTION_CLIENT ]: beacon protection support (client)\n' > "$T/iw-phy0"
check "bcnprot_bands: phy3 (2g) only, not the _CLIENT one (phy0)" "2g" "$(bcnprot_bands)"
apply
check "2g advertises it: its SAE BSS (bcawl3) beacon_prot=1, its WPA2 BSS and 5gl none; 2g restarts alone" \
	"0 1 0 0 REMOVE bcawl3|ADD bss_config=phy3:$G/hostapd-bcawl3.conf" \
	"$rc $(grep -c '^beacon_prot=1$' "$G/hostapd-bcawl3.conf") $(grep -c '^beacon_prot=1$' "$G/bss-bcawl3-1.conf") $(grep -c '^beacon_prot' "$G/hostapd-bcawl0.conf") $(echo "$cmds" | tr '\n' '|' | sed 's/|$//')"
rm -f "$T"/iw-phy*; : > "$T/nets"; apply

# 19. a radio re-probed by the driver (open-wifi radio_rebind): its netdev
# comes back under the same name with a new ifindex; the reload restarts
# that radio alone (hostapd is bound to the old netdev), its station too
rm -f "$T/slots"; WIFI_MAX_BSS=4
for i in 0 1 2 3; do echo "1$i" > "$T/net/bcawl$i/ifindex"; done
{ net 1 a sae password1 "2g 5gl" 1; net 2 b sae password2 2g 2; } > "$T/nets"
apply
check "ids: recorded for the started radios only (bcawl3 13, bcawl0 10)" "0 bcawl0:10 bcawl3:13" \
	"$rc $(for f in "$T"/run/gt-be98-wifi/ids/*; do printf '%s:%s ' "${f##*/}" "$(cat "$f")"; done | sed 's/ $//')"
apply
check "ids: same netdevs, no command" "0 -" "$rc -$cmds"
echo 23 > "$T/net/bcawl3/ifindex"
apply
check "bcawl3 re-probed (ifindex 13 -> 23): that radio alone restarted, whole (its two BSSes)" \
	"0 REMOVE bcawl3|ADD bss_config=phy3:$G/hostapd-bcawl3.conf phy0 bcawl0|phy3 bcawl3 bcawl3-1" \
	"$rc $(echo "$cmds" | tr '\n' '|' | sed 's/|$//') $(hapd | tr '\n' '|' | sed 's/|$//')"
check "re-probe: said so, the new ifindex recorded, bcawl0 untouched" "yes 23 10" \
	"$(grep -q 'radio bcawl3 was re-probed by the Wi-Fi driver' "$T/out" && echo yes || echo no) $(cat "$T/run/gt-be98-wifi/ids/bcawl3") $(cat "$T/run/gt-be98-wifi/ids/bcawl0")"
apply
check "after the restart: no command" "0 -" "$rc -$cmds"
# a radio no longer configured is forgotten (a later re-probe of it is not ours)
{ net 1 a sae password1 2g 1; net 2 b sae password2 2g 2; } > "$T/nets"
apply
check "5gl no longer configured: removed, its id forgotten" "0 REMOVE bcawl0 bcawl3" \
	"$rc $cmds $(ls "$T/run/gt-be98-wifi/ids" | tr '\n' ' ' | sed 's/ $//')"
# a station radio re-probed: its AP interface went with the old wiphy; the
# station restarts (wpa_supplicant is bound to the old netdev), then the APs
rm -f "$T/slots" "$T"/freq-* "$T"/assoc-*
{ printf 'radio=5gl\nchannel=36\nwidth=80\n'; sta; net 1 a sae password1 "2g 5gl" 1; } > "$T/nets"
apply
echo 1 > "$T/net/bcawl0-1/ifindex" 2>/dev/null
check "station radio: running, its id recorded" "0 phy0 bcawl0-1 10" "$rc $(hapd | grep '^phy0') $(cat "$T/run/gt-be98-wifi/ids/bcawl0")"
echo 30 > "$T/net/bcawl0/ifindex"; rm -rf "${T:?}/net/bcawl0-1"; : > "$T/seq"
apply
check "station radio re-probed: the AP interface again, the station restarted, then its APs (A1 order)" \
	"0 iw add bcawl0-1|sta up bcawl0 restart|hapd REMOVE bcawl0-1|hapd ADD bss_config=phy0:$G/hostapd-bcawl0.conf" \
	"$rc $(tr '\n' '|' < "$T/seq" | sed 's/|$//')"
check "station radio re-probed: the new id recorded, 2g untouched (no command for bcawl3)" "30 0" \
	"$(cat "$T/run/gt-be98-wifi/ids/bcawl0") $(echo "$cmds" | grep -c bcawl3)"
# the daemon: started when not running, stopped with the service; stop
# forgets every id (an unload is not a re-probe)
WIFI_REPROBE="$here/../src/sbin/gt-be98-wifi-reprobe"; : > "$T/stalog"
reprobe_start; reprobe_start
check "reprobe daemon: started once" "start $T/run/gt-be98-wifi-reprobe.pid" "$(grep 'reprobe' "$T/stalog")"
reprobe_stop
check "reprobe daemon: stopped" "stop $T/run/gt-be98-wifi-reprobe.pid no" "$(grep '^stop.*reprobe' "$T/stalog") $([ -f "$T/run/gt-be98-wifi-reprobe.pid" ] && echo yes || echo no)"
( stop_hostapd ) >> "$T/out" 2>&1
check "stop: the ids forgotten" "no" "$([ -d "$T/run/gt-be98-wifi/ids" ] && echo yes || echo no)"
for i in 0 1 2 3; do rm -f "$T/net/bcawl$i/ifindex"; done
: > "$T/nets"; apply

# 20. a radio that fails LATE (hostapd answered the ADD, then its setup
# failed: DISABLED in hostapd's list): a failure, never "unchanged"; that
# radio alone retried 3 times (30 s, 2 min, 10 min), then left and reported;
# the other radio untouched; a new config starts over; ENABLED clears it
export GT_BE98_LOG="$T/slog"; : > "$T/slog"
default_status() { return 0; }
rm -f "$T/slots" "$T"/state-*; WIFI_MAX_BSS=4
{ net 1 a sae password1 "2g 5gl" 1; } > "$T/nets"
F="$T/run/gt-be98-wifi/failed/bcawl0"
at() { export GT_BE98_NOW=$1; apply; }
at 1000
check "late failure control: both radios run, no record" "0 phy3 bcawl3|phy0 bcawl0 no" "$rc $(hapd | tr '\n' '|' | sed 's/|$//') $([ -f "$F" ] && echo yes || echo no)"
echo DISABLED > "$T/state-bcawl0"
printf '1000.1: bcawl0: interface state COUNTRY_UPDATE->DISABLED\n1000.2: bcawl0: AP-DISABLED \n' >> "$T/hostapd.log"
at 1001
check "bcawl0 DISABLED: a failure (rc 1), no command, recorded (state, tries 0, retry at +30 s), hostapd's reason kept" \
	"1 - state=DISABLED tries=0 next=1031 given_up=0 yes" \
	"$rc -$cmds $(grep -E '^(state|tries|next|given_up)=' "$F" | tr '\n' ' ')$(grep -q '^reason=.*AP-DISABLED' "$F" && echo yes || echo no)"
check "  syslog: FAILED, retry 1/3 in 30 s; the service output an error" "1 yes" \
	"$(grep -c 'radio bcawl0 FAILED to start (hostapd: DISABLED): .*AP-DISABLED.*; retry 1/3 in 30 s' "$T/slog") $(grep -q ' E radio bcawl0 failed to start' "$T/out" && echo yes || echo no)"
at 1020; check "1020: not due, nothing sent" "1 -" "$rc -$cmds"
nadd=0; tried() { nadd=$((nadd + $(echo "$cmds" | grep -c '^ADD bss_config=phy0:'))); }
at 1031; tried
check "1031: retry 1/3: bcawl0 alone REMOVE + ADD, 2g untouched" "REMOVE bcawl0|ADD bss_config=phy0:$G/hostapd-bcawl0.conf 1 0" \
	"$(echo "$cmds" | tr '\n' '|' | sed 's/|$//') $(grep '^tries=' "$F" | cut -d= -f2) $(echo "$cmds" | grep -c bcawl3)"
at 1032; tried
check "1032: DISABLED again: retry 2/3 in 120 s, nothing sent" "1 - next=1152 1" "$rc -$cmds $(grep '^next=' "$F") $(grep -c 'FAILED again (hostapd: DISABLED, try 1/3).*retry 2/3 in 120 s' "$T/slog")"
at 1100; tried; at 1152; tried; at 1153; tried
check "1152: retry 2; 1153: DISABLED again, retry 3/3 in 600 s" "tries=2 next=1753" "$(grep '^tries=' "$F") $(grep '^next=' "$F")"
at 1753; tried; at 1754; tried
check "1753: retry 3; 1754: given up, said once" "tries=3 given_up=1 1" \
	"$(grep '^tries=' "$F") $(grep '^given_up=' "$F") $(grep -c 'radio bcawl0 FAILED to start (hostapd: DISABLED) after 3 retries' "$T/slog")"
at 5000; tried; at 9000; tried
check "given up: no more command, exactly 3 retries (ADDs) in all, never a command for 2g" "- 3 0" \
	"-$cmds $nadd $(grep -c 'bcawl3' "$T/cmds")"
check "given up: no second syslog line" "1" "$(grep -c 'after 3 retries' "$T/slog")"
: > "$T/out"; ( status ) >> "$T/out" 2>&1; src=$?
check "status: an error naming bcawl0, given up, the reason; non-zero" "yes 1" \
	"$(grep -q ' E radio bcawl0 FAILED to start (DISABLED), given up after 3 retries: .*AP-DISABLED' "$T/out" && echo yes || echo no) $src"
# a new config of that radio: a new count, restarted at once
sed -i '1i radio=5gl\nchannel=44' "$T/nets"
at 9001
check "5gl channel changed: restarted at once" "REMOVE bcawl0|ADD bss_config=phy0:$G/hostapd-bcawl0.conf" "$(echo "$cmds" | tr '\n' '|' | sed 's/|$//')"
at 9002
check "  still DISABLED: a NEW record (tries 0, next +30)" "tries=0 next=9032" "$(grep '^tries=' "$F") $(grep '^next=' "$F")"
rm -f "$T/state-bcawl0"; at 9003
check "ENABLED: the record goes, recovered said, rc 0" "0 no 1" "$rc $([ -f "$F" ] && echo yes || echo no) $(grep -c 'radio bcawl0 recovered (ENABLED)' "$T/slog")"
# a failure INSIDE the ADD (hostapd answers FAIL): the same budget
sed -i '/^radio=5gl$/d; /^channel=44$/d' "$T/nets"
echo 'hostapd-bcawl0' > "$T/fail"; at 9100
check "ADD FAIL: rc 1, recorded ADD-FAILED, retry at +30" "1 state=ADD-FAILED next=9130" "$rc $(grep '^state=' "$F") $(grep '^next=' "$F")"
at 9110; check "  9110: held (no ADD for bcawl0)" "0" "$(echo "$cmds" | grep -c 'ADD bss_config=phy0')"
at 9130; check "  9130: retry 1 (the ADD sent again, FAIL again: retry 2 in 120 s)" "1 tries=1 next=9250" \
	"$(echo "$cmds" | grep -c 'ADD bss_config=phy0') $(grep '^tries=' "$F") $(grep '^next=' "$F")"
rm -f "$T/fail"; at 9250; at 9251
check "  9250: the retry works; 9251: ENABLED, record cleared" "no" "$([ -f "$F" ] && echo yes || echo no)"
# a radio leaving the plan takes its record with it; stop forgets all
echo DISABLED > "$T/state-bcawl0"; at 9300
{ net 1 a sae password1 2g 1; } > "$T/nets"; rm -f "$T/state-bcawl0"; at 9301
check "5gl out of the plan: its record gone" "no" "$([ -f "$F" ] && echo yes || echo no)"
( stop_hostapd ) >> "$T/out" 2>&1
check "stop: no failed dir" "no" "$([ -d "$T/run/gt-be98-wifi/failed" ] && echo yes || echo no)"
unset GT_BE98_NOW GT_BE98_LOG; : > "$T/nets"; apply

# 21. a dead hostapd (the stub: its pid killed, the fake's interface list
# gone with it): the reload the watcher runs restarts the process and adds
# every radio again, said; a dead process is never "unchanged"
rm -f "$T/slots" "$T"/state-*
{ net 1 a sae password1 "2g 5gl" 1; } > "$T/nets"; apply
kill "$(cat "$T/run/hostapd-wifi.pid")" 2>/dev/null; rm -f "$T/hapd"; sleep 0.2 2>/dev/null || sleep 1
: > "$T/daemon"; apply
check "dead hostapd: rc 0, the process started again, both radios added, said" \
	"0 start yes ADD bss_config=phy3:$G/hostapd-bcawl3.conf|ADD bss_config=phy0:$G/hostapd-bcawl0.conf yes" \
	"$rc $(cut -d' ' -f1 "$T/daemon" | tr '\n' '|' | sed 's/|$//') $(hap_running && echo yes || echo no) $(echo "$cmds" | tr '\n' '|' | sed 's/|$//') $(grep -q '! hostapd had died' "$T/out" && echo yes || echo no)"
: > "$T/nets"; apply

if [ $fail = 0 ]; then echo "ALL OK ($n checks)"; else echo "FAILED"; cat "$T/out"; fi
exit $fail

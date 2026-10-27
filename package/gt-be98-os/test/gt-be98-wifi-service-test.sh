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
trap 'kill $(cat "$T/run/hostapd-wifi.pid" 2>/dev/null) 2>/dev/null; rm -rf "$T"' EXIT
export GT_BE98_RUN="$T/run" GT_BE98_SYSNET="$T/net" GT_BE98_HAP_LOG="$T/hostapd.log" \
	GT_BE98_WIFI_GEN="$here/../src/sbin/gt-be98-wifi-gen" FAKE="$T"
mkdir -p "$T/bin" "$T/run"
for p in 0:a4 1:a8 2:ac 3:a0; do	# bcawl<i>: phy<i>, address
	mkdir -p "$T/net/bcawl${p%%:*}/phy80211"
	echo "phy${p%%:*}" > "$T/net/bcawl${p%%:*}/phy80211/name"
	echo "00:00:5e:00:53:${p#*:}" > "$T/net/bcawl${p%%:*}/address"
done
cat > "$T/bin/hostapd_cli" <<'X'
#!/bin/sh
# hostapd_cli -p DIR -i NAME raw CMD [ARG]
while [ $# -gt 0 ]; do case $1 in -p|-i) shift 2 ;; raw) shift; break ;; *) shift ;; esac; done
S=$FAKE/hapd
p=$(cat "$FAKE/run/hostapd-wifi.pid" 2>/dev/null)
[ -n "$p" ] && kill -0 "$p" 2>/dev/null || { echo "Failed to connect to hostapd"; exit 255; }
touch "$S"
case "$1" in PING|INTERFACES) ;; *) echo "$*" >> "$FAKE/cmds" ;; esac
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
	sleep 1000 & echo $! > "$pf"; rm -f "$FAKE/hapd"
	echo "start $*" >> "$FAKE/daemon" ;;
*" --stop "*)	pf=; while [ $# -gt 0 ]; do [ "$1" = --pidfile ] && pf=$2; shift; done
	kill "$(cat "$pf")" 2>/dev/null; rm -f "$FAKE/hapd"; echo stop >> "$FAKE/daemon" ;;
esac
exit 0
X
# iw: "phy <phy> info" prints $FAKE/iw-<phy> when present (the interface
# combination), nothing otherwise; every other command succeeds silently
cat > "$T/bin/iw" <<'X'
#!/bin/sh
[ "$1" = phy ] && [ "$3" = info ] && [ -f "$FAKE/iw-$2" ] && cat "$FAKE/iw-$2"
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
br_create() { return 0; }; vlan_attach() { return 0; }
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

# 10. a refused list: nothing sent, everything left as it was
cp "$T/nets" "$T/nets.ok"; before=$(hapd)
net 60 bad psk2 password6 6g 60 >> "$T/nets"
apply
check "refused list: rc 1, no command, hostapd as before" "1 - same" "$rc -$cmds $( [ "$(hapd)" = "$before" ] && echo same || echo changed)"
cp "$T/nets.ok" "$T/nets"

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

if [ $fail = 0 ]; then echo "ALL OK ($n checks)"; else echo "FAILED"; cat "$T/out"; fi
exit $fail

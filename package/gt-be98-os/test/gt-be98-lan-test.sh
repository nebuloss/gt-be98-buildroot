#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# Unit test of the wired-LAN policy (no device, no root): sh test/gt-be98-lan-test.sh
#  1. sbin/gt-be98-netguard --selftest (the bridge-port verdicts, with controls);
#  2. init.d/gt-be98-lan load_conf: which LAN_PORTS / LAN_BRIDGE / LAN_ADDR it
#     accepts (rnr0 never);
#  3. init.d/gt-be98-router load_conf: a router LAN may be the wired LAN bridge,
#     never a bare wired port or a brwifi bridge.
# The service scripts are sourced with the OpenRC helpers stubbed.
set -u
here=$(cd "$(dirname "$0")" && pwd)
SRC="$here/../src"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
pass=0 fail=0
ok() { pass=$((pass + 1)); echo "ok   $*"; }
ko() { fail=$((fail + 1)); echo "FAIL $*"; }

# 1. netguard verdicts
if sh "$SRC/sbin/gt-be98-netguard" --selftest > "$T/ng.out" 2>&1; then
	ok "netguard --selftest ($(tail -n1 "$T/ng.out"))"
else
	ko "netguard --selftest"; cat "$T/ng.out"
fi

# 2. gt-be98-lan conf validation: <expect 0|1> <LAN_PORTS> [LAN_BRIDGE] [LAN_ADDR]
lan_case() {
	printf 'LAN_PORTS="%s"\nLAN_BRIDGE="%s"\nLAN_ADDR="%s"\n' "$2" "${3:-br-lan}" "${4:-}" > "$T/lan.conf"
	(
		eerror() { :; }; ebegin() { :; }; eend() { :; }; ewarn() { :; }
		LAN_CONF_FILE="$T/lan.conf"
		. "$SRC/init.d/gt-be98-lan"
		load_conf
	)
	r=$?; [ $r -ne 0 ] && r=1
	if [ "$r" = "$1" ]; then ok "lan load_conf rc=$1: ports='$2' bridge=${3:-br-lan} addr=${4:-}"
	else ko "lan load_conf want rc=$1 got $r: ports='$2' bridge=${3:-br-lan} addr=${4:-}"; fi
}
lan_case 0 "rnr1"
lan_case 0 "rnr1 rnr2 rnr3"
lan_case 1 "rnr0"				# the uplink
lan_case 1 "rnr1 rnr0"				# ... anywhere in the list
lan_case 1 "eth0"				# the USB lifeline
lan_case 1 "bcawl0"				# Wi-Fi joins through hostapd, not here
lan_case 1 ""					# LAN off: nothing to start
lan_case 1 "rnr1" brwifi1			# never a Wi-Fi network bridge
lan_case 0 "rnr2" br-lan 192.168.50.1/24
lan_case 1 "rnr2" br-lan 192.168.50.1		# not CIDR

# 2a. LAN_MTU: 1280..10240 (jumbo, the Runner's max_mtu), empty = unchanged
mtu_case() {
	printf 'LAN_PORTS="rnr2"\nLAN_MTU="%s"\n' "$2" > "$T/lan.conf"
	(
		eerror() { :; }; ebegin() { :; }; eend() { :; }; ewarn() { :; }
		LAN_CONF_FILE="$T/lan.conf"
		. "$SRC/init.d/gt-be98-lan"
		load_conf
	)
	r=$?; [ $r -ne 0 ] && r=1
	if [ "$r" = "$1" ]; then ok "lan load_conf rc=$1: LAN_MTU='$2'"
	else ko "lan load_conf want rc=$1 got $r: LAN_MTU='$2'"; fi
}
mtu_case 0 ""
mtu_case 0 9000
mtu_case 0 1280
mtu_case 0 10240
mtu_case 1 10241
mtu_case 1 1279
mtu_case 1 09000

# 2b. gt-be98-lan forward filter: into the bridge only replies, DNAT, and UDP to
# an IPv4 multicast group (forwarded only by router mode's igmpproxy), then drop
r=$(
	eerror() { :; }; ebegin() { :; }; eend() { :; }; ewarn() { :; }
	nft() { cat; }
	LAN_CONF_FILE="$T/lan.conf"
	. "$SRC/init.d/gt-be98-lan"
	LAN_BRIDGE=br-lan; lan_nft
)
o=$(printf '%s\n' "$r" | sed -n 's/^[[:space:]]*\(oifname "br-lan" .*\)$/\1/p' | tr '\n' '|')
if [ "$o" = 'oifname "br-lan" iifname "br-lan" accept|oifname "br-lan" ct state established,related accept|oifname "br-lan" ct status dnat accept|oifname "br-lan" ip daddr 224.0.0.0/4 meta l4proto udp accept|oifname "br-lan" counter drop|' ]; then
	ok "lan forward filter: replies, DNAT, UDP multicast, then drop"
else
	ko "lan forward filter: got [$o]"
fi

# 3. gt-be98-router LAN names: <expect 0|1> <ROUTER_LANS>
router_case() {
	mkdir -p "$T/router"
	printf 'ROUTER_WAN="rnr0"\nROUTER_LANS="%s"\n' "$2" > "$T/router/router.conf"
	(
		eerror() { :; }; ebegin() { :; }; eend() { :; }; ewarn() { :; }
		ROUTER_DIR="$T/router"
		. "$SRC/init.d/gt-be98-router"
		load_conf
	)
	r=$?; [ $r -ne 0 ] && r=1
	if [ "$r" = "$1" ]; then ok "router load_conf rc=$1: LANS='$2'"
	else ko "router load_conf want rc=$1 got $r: LANS='$2'"; fi
}
router_case 0 "bcawl3=192.168.83.1/24"
router_case 0 "br-lan=192.168.50.1/24"
router_case 0 "bcawl3=192.168.83.1/24 br-lan=192.168.50.1/24"
router_case 1 "rnr1=192.168.50.1/24"		# a bare wired port
router_case 1 "rnr0=192.168.50.1/24"
router_case 1 "brwifi1=192.168.50.1/24"	# a Wi-Fi network bridge

echo "gt-be98-lan-test: $pass ok, $fail failed"
[ $fail -eq 0 ]

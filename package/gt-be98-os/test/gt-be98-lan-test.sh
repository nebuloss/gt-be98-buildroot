#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# Unit test of the wired-LAN policy (no device, no root): sh test/gt-be98-lan-test.sh
#  1. sbin/gt-be98-netguard --selftest (the bridge-port verdicts, with controls);
#  2. init.d/gt-be98-lan load_conf: which LAN_PORTS / LAN_BRIDGE / LAN_ADDR it
#     accepts (rnr0 never);
#  2c-2e. the routed wired LAN (D19): the rule set in NAT / refused / plain mode
#     (checked by the kernel with `unshare -rn nft -c -f`, with a bad-rule-set
#     control), the subnet helpers and the NAT clash check;
#  3. init.d/gt-be98-router load_conf: a router LAN may be the wired LAN bridge,
#     never a bare wired port or a brwifi bridge; refused when gt-be98-lan owns
#     an address on a bridge ROUTER_LANS does not list.
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
	LAN_BRIDGE=br-lan; lan_nft_text
)
o=$(printf '%s\n' "$r" | sed -n 's/^[[:space:]]*\(oifname "br-lan" .*\)$/\1/p' | tr '\n' '|')
if [ "$o" = 'oifname "br-lan" iifname "br-lan" accept|oifname "br-lan" ct state established,related accept|oifname "br-lan" ct status dnat accept|oifname "br-lan" ip daddr 224.0.0.0/4 meta l4proto udp accept|oifname "br-lan" counter drop|' ]; then
	ok "lan forward filter: replies, DNAT, UDP multicast, then drop"
else
	ko "lan forward filter: got [$o]"
fi

# nft dry run in a user + network namespace (kernel-checked, no root needed):
# 0 ok, 1 rejected, 2 not available here (then the cases say SKIP, never PASS)
nft_check() {
	command -v unshare >/dev/null 2>&1 && [ -x "${NFT:-/sbin/nft}" ] || return 2
	unshare -rn "${NFT:-/sbin/nft}" -c -f "$1" >"$T/nft.err" 2>&1 || return 1
}
# the checker itself: a known-bad rule set must be rejected
printf 'table inet t {\n chain fwd {\n  type filter hook forward priority 0; policy accept;\n }\n}\n' > "$T/bad.nft"
nft_check "$T/bad.nft"; r=$?
case $r in 1) ok "nft -c control: a bad rule set (chain named fwd) is rejected";; 2) echo "SKIP nft -c: no unshare/nft here";; *) ko "nft -c control: the bad rule set was accepted";; esac
NFT_OK=$r

# 2c/2d. the routed LAN rule set: NAT mode and refused mode
lan_text() {
	(
		eerror() { :; }; ebegin() { :; }; eend() { :; }; ewarn() { :; }
		LAN_CONF_FILE="$T/lan.conf"
		. "$SRC/init.d/gt-be98-lan"
		LAN_BRIDGE=br-lan; LAN_ADDR=192.168.50.1/24; lan_nft_text "$@"
	)
}
lan_text rnr0 nat > "$T/nat.nft"
o=$(sed -n 's/^[[:space:]]*\(iifname "br-lan" .*\|oifname "rnr0" ip saddr .*\)$/\1/p' "$T/nat.nft" | tr '\n' '|')
if [ "$o" = 'iifname "br-lan" oifname "rnr0" accept|iifname "br-lan" counter drop|oifname "rnr0" ip saddr 192.168.50.0/24 masquerade|' ]; then
	ok "routed LAN (nat): br-lan -> WAN only, then drop; masquerade 192.168.50.0/24 out of rnr0"
else ko "routed LAN (nat): got [$o]"; fi
if [ $NFT_OK != 2 ]; then nft_check "$T/nat.nft" && ok "routed LAN (nat): nft -c accepts it" || { ko "routed LAN (nat): nft -c"; cat "$T/nft.err"; }; fi
lan_text rnr0 refused > "$T/ref.nft"
o=$(sed -n 's/^[[:space:]]*\(iifname "br-lan" .*\|.*masquerade\)$/\1/p' "$T/ref.nft" | tr '\n' '|')
if [ "$o" = 'iifname "br-lan" oifname "rnr0" meta nfproto ipv6 accept|iifname "br-lan" counter drop|' ] && grep -q '^delete table ip gt_be98_lan_nat' "$T/ref.nft"; then
	ok "routed LAN (refused): IPv6 to the WAN only, then drop; no masquerade, NAT table deleted"
else ko "routed LAN (refused): got [$o]"; fi
if [ $NFT_OK != 2 ]; then nft_check "$T/ref.nft" && ok "routed LAN (refused): nft -c accepts it" || { ko "routed LAN (refused): nft -c"; cat "$T/nft.err"; }; fi
lan_text > "$T/plain.nft"
if [ $NFT_OK != 2 ]; then nft_check "$T/plain.nft" && ok "plain LAN (no LAN_ADDR): nft -c accepts it" || { ko "plain LAN: nft -c"; cat "$T/nft.err"; }; fi
if ! grep -qE '^[[:space:]]*iifname "br-lan"' "$T/plain.nft"; then ok "plain LAN: nothing filtered out of the bridge (router mode may own it)"
else ko "plain LAN: an out-of-bridge rule without LAN_ADDR"; fi

# 2e. the subnet helpers and the NAT clash check (WAN address, Wi-Fi station routed network)
lan_fn() {
	(
		eerror() { :; }; ebegin() { :; }; eend() { :; }; ewarn() { :; }
		LAN_CONF_FILE="$T/lan.conf"; GT_BE98_STA_ROUTED="$T/sta.routed"
		. "$SRC/init.d/gt-be98-lan"
		wan_addrs() { echo "$WANA"; }
		LAN_ADDR=192.168.50.1/24; "$@"
	)
}
ov() { if lan_fn cidr_overlap "$2" "$3"; then r=0; else r=1; fi
	if [ $r = $1 ]; then ok "cidr_overlap $2 $3 = $1"; else ko "cidr_overlap $2 $3 want $1"; fi; }
ov 0 192.168.50.1/24 192.168.50.200/24
ov 1 192.168.50.1/24 192.168.51.1/24
ov 0 192.168.0.0/16 192.168.50.1/24
ov 1 10.0.0.95/24 192.168.50.1/24
[ "$(lan_fn lan_subnet)" = 192.168.50.0/24 ] && ok "lan_subnet 192.168.50.1/24 = 192.168.50.0/24" || ko "lan_subnet: $(lan_fn lan_subnet)"
: > "$T/sta.routed"
WANA=10.0.0.95/24; export WANA
[ -z "$(lan_fn nat_clash rnr0)" ] && ok "nat_clash: WAN 10.0.0.95/24, no station networks -> none" || ko "nat_clash: false clash"
WANA=192.168.50.7/24
case "$(lan_fn nat_clash rnr0)" in *"WAN address 192.168.50.7/24"*) ok "nat_clash: WAN 192.168.50.7/24 inside the LAN -> refused";; *) ko "nat_clash: WAN clash not seen";; esac
WANA=10.0.0.95/24; printf 'brwifi60 10.60.0.0/16\n' > "$T/sta.routed"
[ -z "$(lan_fn nat_clash rnr0)" ] && ok "nat_clash: station network 10.60.0.0/16 -> none" || ko "nat_clash: false station clash"
printf 'brwifi60 10.60.0.0/16\nbrwifi50 192.168.50.0/24\n' > "$T/sta.routed"
case "$(lan_fn nat_clash rnr0)" in *"station routed network 192.168.50.0/24"*) ok "nat_clash: station network 192.168.50.0/24 -> refused";; *) ko "nat_clash: station clash not seen";; esac

# 3. gt-be98-router LAN names: <expect 0|1> <ROUTER_LANS>
router_case() {
	mkdir -p "$T/router"
	printf 'ROUTER_WAN="rnr0"\nROUTER_LANS="%s"\n' "$2" > "$T/router/router.conf"
	(
		eerror() { :; }; ebegin() { :; }; eend() { :; }; ewarn() { :; }
		ROUTER_DIR="$T/router"; GT_BE98_LAN_APPLIED="$T/lan.applied"
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
# one owner per LAN: gt-be98-lan owns an address on br-lan -> router mode must list br-lan
printf 'bridge br-lan\nnft\naddr 192.168.50.1/24 br-lan\nnat rnr0 192.168.50.0/24\n' > "$T/lan.applied"
router_case 1 "bcawl3=192.168.83.1/24"		# br-lan owned by gt-be98-lan, not listed
router_case 0 "bcawl3=192.168.83.1/24 br-lan=192.168.50.1/24"
rm -f "$T/lan.applied"
router_case 0 "bcawl3=192.168.83.1/24"		# control: no wired LAN address

echo "gt-be98-lan-test: $pass ok, $fail failed"
[ $fail -eq 0 ]

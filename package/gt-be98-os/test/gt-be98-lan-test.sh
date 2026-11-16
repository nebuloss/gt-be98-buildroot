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
lan_case 0 ""					# nothing configured: a clean no-op (D41: in the default runlevel)
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

# 4. VLAN jacks (LAN_PORT_<port>): profiles, network resolution, BPDU guard,
# the apply/reload/stop sequence, the empty-config no-op
# 4a. profiles: <expect 0|1> <conf lines (\n-separated)> [VPORTS expected]
vp_case() {
	printf "$2\n" > "$T/lan.conf"
	r=$(
		eerror() { :; }; ebegin() { :; }; eend() { :; }; ewarn() { :; }
		LAN_CONF_FILE="$T/lan.conf"
		. "$SRC/init.d/gt-be98-lan"
		WIFI_TRUNK_T=${TRUNK:-rnr0}; wifi_trunk() { echo "$WIFI_TRUNK_T"; }
		load_conf || exit 1
		echo "ports=[$VPORTS] $(for p in $VPORTS; do eval "printf '%s=%s ' $p \$VNATIVE_$p"; done)"
	)
	rc=$?; [ $rc -ne 0 ] && rc=1
	if [ "$rc" = "$1" ] && { [ $rc = 1 ] || [ -z "${3:-}" ] || [ "$r" = "$3" ]; }; then ok "VLAN profile rc=$1: $(printf "$2" | tr '\n' ' ') ${3:-}"
	else ko "VLAN profile want rc=$1 [${3:-}] got rc=$rc [$r]: $2"; fi
}
vp_case 0 'LAN_PORT_rnr2="native=921 tagged=none"' "ports=[rnr2] rnr2=921 "
vp_case 0 'LAN_PORT_rnr2="native=921"' "ports=[rnr2] rnr2=921 "
vp_case 0 'LAN_PORT_rnr2="native=921"\nLAN_PORT_rnr3="native=30"' "ports=[rnr2 rnr3] rnr2=921 rnr3=30 "
vp_case 0 'LAN_PORT_rnr2="native=921 enabled=0"' "ports=[] "		# disabled: no jack
vp_case 0 '' "ports=[] "						# nothing at all: no error (the no-op)
vp_case 0 'LAN_PORT_rnr1="native=921"' "ports=[] "			# rnr1 is never a bare VLAN port any more (its jacks: 4b0)
vp_case 1 'LAN_PORT_rnr2="native=921 tagged=all"'			# a bare port: tagged=none only (the 2.5G jacks take a list: 4f)
vp_case 1 'LAN_PORT_rnr2="native=921 tagged=30"'
vp_case 1 'LAN_PORT_rnr2="native=0"'
vp_case 1 'LAN_PORT_rnr2="native=4095"'
vp_case 1 'LAN_PORT_rnr2="native=0921"'
vp_case 1 'LAN_PORT_rnr2="tagged=none"'					# no native
vp_case 1 'LAN_PORT_rnr2="native=921 enabled=2"'
vp_case 1 'LAN_PORT_rnr2="native=921 foo=1"'
vp_case 1 'LAN_PORT_rnr2="native=921;reboot"'				# characters outside the profile's
vp_case 1 'LAN_PORT_rnr0="native=921"'					# the uplink, never
vp_case 1 'LAN_PORT_rnr2="native=921"\nLAN_PORTS="rnr2"'		# one or the other
vp_case 0 'LAN_PORT_rnr2="native=921"\nLAN_PORTS="rnr3"' "ports=[rnr2] rnr2=921 "
TRUNK=rnr2 vp_case 1 'LAN_PORT_rnr2="native=921"'			# the Wi-Fi trunk port
TRUNK=rnr3 vp_case 0 'LAN_PORT_rnr2="native=921"' "ports=[rnr2] rnr2=921 "

# 4b0. the 2.5G jacks (RTL8372 ports 4..7): LAN_JACK_<n>, or RC9's
# LAN_PORT_rnr1 for all four while no LAN_JACK_<n> line exists; a refused
# jack is off (logged), the others unaffected; VLAN 1 never (the routed
# LAN's bare rnr1). <expect rc> <conf lines> [expected "jacks=[..] n=V .."] [an error text expected]
jk_case() {
	printf "$2\n" > "$T/lan.conf"
	: > "$T/jk.err"
	r=$(
		eerror() { echo "E $*" >> "$T/jk.err"; }; ebegin() { :; }; eend() { :; }; ewarn() { echo "W $*" >> "$T/jk.err"; }
		LAN_CONF_FILE="$T/lan.conf"
		. "$SRC/init.d/gt-be98-lan"
		WIFI_TRUNK_T=${TRUNK:-rnr0}; wifi_trunk() { echo "$WIFI_TRUNK_T"; }
		load_conf || exit 1
		echo "jacks=[$JACKS] $(for n in $JACKS; do eval "printf '%s=%s ' $n \$JNATIVE_$n"; done)"
	)
	rc=$?; [ $rc -ne 0 ] && rc=1
	e=ok; [ -z "${4:-}" ] || grep -q -- "$4" "$T/jk.err" || e="no error '$4' in [$(tr '\n' '|' < "$T/jk.err")]"
	if [ "$rc" = "$1" ] && { [ $rc = 1 ] || [ "$r" = "$3" ]; } && [ "$e" = ok ]; then ok "2.5G jacks rc=$1: $(printf "$2" | tr '\n' ' ') -> ${3:-refused}${4:+ ($4)}"
	else ko "2.5G jacks want rc=$1 [${3:-}] got rc=$rc [$r] $e: $2"; fi
}
jk_case 0 'LAN_JACK_6="native=921 tagged=none enabled=1"' "jacks=[6] 6=921 "
jk_case 0 'LAN_JACK_4="native=921"\nLAN_JACK_6="native=30"' "jacks=[4 6] 4=921 6=30 "
jk_case 0 'LAN_JACK_5="native=921 enabled=0"' "jacks=[] "				# disabled: off
jk_case 0 'LAN_JACK_4=""\nLAN_JACK_5=""\nLAN_JACK_6=""\nLAN_JACK_7=""' "jacks=[] "	# the shipped empties
jk_case 0 'LAN_PORT_rnr1="native=921 tagged=none enabled=1"' "jacks=[4 5 6 7] 4=921 5=921 6=921 7=921 "	# RC9 migration: all four
jk_case 0 'LAN_PORT_rnr1="native=921 enabled=0"' "jacks=[] "
jk_case 0 'LAN_PORT_rnr1="native=921"\nLAN_JACK_6="native=30"' "jacks=[6] 6=30 " "W LAN_PORT_rnr1 ignored"	# LAN_JACK_<n> wins
jk_case 0 'LAN_PORT_rnr1=""\nLAN_JACK_6="native=30"' "jacks=[6] 6=30 "		# what the web UI writes: rnr1 emptied, a line per jack with a profile
jk_case 0 'LAN_PORT_rnr1=""' "jacks=[] "						# ... no jack with a profile: all off
jk_case 0 'LAN_PORT_rnr1="native=921"\nLAN_JACK_6=""' "jacks=[4 5 6 7] 4=921 5=921 6=921 7=921 "	# an EMPTY LAN_JACK_<n> is no profile: still the migration
jk_case 0 'LAN_PORT_rnr1="native=921"\nLAN_JACK_8="native=30"' "jacks=[4 5 6 7] 4=921 5=921 6=921 7=921 "	# no jack 8: still the migration
jk_case 0 'LAN_JACK_4="native=921 tagged=all,30"\nLAN_JACK_6="native=30"' "jacks=[6] 6=30 " "E LAN_JACK_4: tagged=all,30 refused.*jack 4 off"	# one refused, the other kept
for b in 'native=1' 'native=0' 'native=4095' 'native=0921' 'tagged=none' 'native=921 enabled=2' 'native=921 foo=1' 'native=921;reboot' 'native=921 tagged=921' 'native=921 tagged=1'; do
	jk_case 0 "LAN_JACK_7=\"$b\"\nLAN_JACK_4=\"native=30\"" "jacks=[4] 4=30 " "jack 7 off"
done
jk_case 0 'LAN_JACK_7="native=1"' "jacks=[] " "VLAN 1 is the untagged LAN on bare rnr1"
jk_case 0 'LAN_PORT_rnr1="native=1"' "jacks=[] " "VLAN 1 is the untagged LAN on bare rnr1"	# the migration too
jk_case 0 'LAN_PORT_rnr1="native=921 tagged=921"' "jacks=[] " "the four 2.5G jacks are off"	# the migration's profile: a tag equal to its native
TRUNK=rnr1 jk_case 0 'LAN_JACK_6="native=921"' "jacks=[] " "rnr1 is the Wi-Fi trunk port"
TRUNK=rnr2 jk_case 0 'LAN_JACK_6="native=921"' "jacks=[6] 6=921 "			# control: the trunk elsewhere
# never mixed with the routed LAN's rnr1 (all four jacks untagged on bare rnr1, VLAN 1)
jk_case 1 'LAN_PORTS="rnr1"\nLAN_JACK_6="native=921"' "" "rnr1 is in LAN_PORTS.*one or the other"
jk_case 0 'LAN_PORTS="rnr1"\nLAN_JACK_6="native=921 enabled=0"' "jacks=[] "		# a disabled jack: no conflict
jk_case 1 'LAN_PORTS="rnr1"\nLAN_PORT_rnr1="native=921"'				# the migration's profile
jk_case 0 'LAN_PORTS="rnr1"\nLAN_JACK_6=""' "jacks=[] "				# control: no profile
jk_case 0 'LAN_PORTS="rnr2"\nLAN_JACK_6="native=921"' "jacks=[6] 6=921 "		# control: another routed port

# the shipped conf: nothing configured (the service in the default runlevel is a no-op)
r=$(
	eerror() { :; }; LAN_CONF_FILE="$SRC/conf.d/gt-be98-lan"
	. "$SRC/init.d/gt-be98-lan"
	wifi_trunk() { echo rnr0; }
	load_conf && echo "ok [$LAN_PORTS] [$VPORTS] [$LAN_ADDR]"
)
[ "$r" = "ok [] [] []" ] && ok "the shipped conf.d: loads, no LAN port, no VLAN jack, no address (start is the no-op)" || ko "the shipped conf.d: [$r]"

# a conf saved by an older image (/jffs state.tgz restores it over the image
# default at every boot): the LAN_PORT_* keys are ABSENT, not empty. Same as
# empty: loads, no jack, and start runs no command at all
grep -v '^LAN_PORT_' "$SRC/conf.d/gt-be98-lan" > "$T/old.conf"
r=$(
	eerror() { :; }; LAN_CONF_FILE="$T/old.conf"
	. "$SRC/init.d/gt-be98-lan"
	wifi_trunk() { echo rnr0; }
	load_conf && echo "ok [$LAN_PORTS] [$VPORTS] keys=$(grep -c '^LAN_PORT_' "$T/old.conf")"
)
[ "$r" = "ok [] [] keys=0" ] && ok "older-image conf (LAN_PORT_* absent): loads, no LAN port, no VLAN jack" || ko "older-image conf: [$r]"

# 4b. VLAN -> network bridge: the running Wi-Fi's l2.conf, else the web UI's
# file as a whole (WIFI_VLANS, then its network list), else the defaults file
nb() {
	(
		eerror() { :; }; LAN_CONF_FILE="$T/lan.conf"
		GT_BE98_WIFI_L2="$T/l2.conf" GT_BE98_WIFI_CONFS="$T/wifi-ap $T/wifi"
		. "$SRC/init.d/gt-be98-lan"
		lan_net_bridge "$1" || echo none
	)
}
nb_case() { r=$(nb "$1"); if [ "$r" = "$2" ]; then ok "VLAN $1 -> $2 ($3)"; else ko "VLAN $1: want $2 got $r ($3)"; fi; }
rm -f "$T/l2.conf" "$T/wifi-ap" "$T/wifi"
printf 'country=FR\nradio=2g\nchannel=6\nnetwork=7\nssid=a\nvlan=921\nnetwork=12\nssid=b\nvlan=30\nradio=5gl\nvlan=99\n' > "$T/networks.conf"
printf 'WIFI_NETWORKS=%s\nWIFI_VLANS=""\n' "$T/networks.conf" > "$T/wifi"
nb_case 921 brwifi7 "defaults file, network list"
nb_case 30 brwifi12 "the second network"
nb_case 99 none "a vlan= line outside a network block"
nb_case 31 none "no network on it"
printf 'WIFI_NETWORKS=""\nWIFI_VLANS="brwifi3:31"\n' > "$T/wifi-ap"
nb_case 31 brwifi3 "the web UI file's WIFI_VLANS"
nb_case 921 none "the web UI file wins as a whole (its list is empty)"
printf 'WIFI_TRUNK="rnr0"\nWIFI_VLANS="brwifi40:921"\n' > "$T/l2.conf"
nb_case 921 brwifi40 "the running Wi-Fi's effective list first"
nb_case 31 none "... and only it while Wi-Fi runs"
rm -f "$T/l2.conf" "$T/wifi-ap"

# 4c. the BPDU guard rule set, kernel-checked
gt() {
	(
		eerror() { :; }; LAN_CONF_FILE="$T/lan.conf"
		. "$SRC/init.d/gt-be98-lan"
		guard_nft_text "$@"
	)
}
gt "rnr1" "rnr0.921" "" > "$T/g1.nft"
gt "rnr1 rnr3" "rnr0.921 rnr0.30" "rnr3" > "$T/g2.nft"
o=$(sed -n 's/^[[:space:]]*\(i\|o\)ifname \(.*\)$/\1 \2/p' "$T/g1.nft" | tr '\n' '|')
if [ "$o" = 'i @tripped drop|i "rnr1" ether daddr 01:80:c2:00:00:00 add @tripped { iifname } counter name "bpdu_in_rnr1" drop|o @tripped drop|o "rnr0.921" ether daddr 01:80:c2:00:00:00 counter name "bpdu_out_rnr0_921" drop|' ]
then ok "BPDU guard rules: latched ports dropped both ways; a BPDU from the jack latches it; none into the trunk VLAN"
else ko "BPDU guard rules: got [$o]"; fi
grep -q 'elements = { "rnr3" }' "$T/g2.nft" && ! grep -q elements "$T/g1.nft" &&
	ok "BPDU guard: a latched port stays latched across a reload (elements), none otherwise" || ko "BPDU guard: latched elements"
gt "" "rnr0.921 rnr0.30" "" "921 30" > "$T/g3.nft"
o=$(sed -n 's/^[[:space:]]*\(i\|o\)ifname \(.*\)$/\1 \2/p' "$T/g3.nft" | tr '\n' '|')
if [ "$o" = 'i @tripped drop|i "rnr1.921" ether daddr 01:80:c2:00:00:00 add @bpdu_src_921 { ether saddr }|i "rnr1.921" ether daddr 01:80:c2:00:00:00 counter name "bpdu_in_rnr1_921" drop|i "rnr1.30" ether daddr 01:80:c2:00:00:00 add @bpdu_src_30 { ether saddr }|i "rnr1.30" ether daddr 01:80:c2:00:00:00 counter name "bpdu_in_rnr1_30" drop|o @tripped drop|o "rnr0.921" ether daddr 01:80:c2:00:00:00 counter name "bpdu_out_rnr0_921" drop|o "rnr0.30" ether daddr 01:80:c2:00:00:00 counter name "bpdu_out_rnr0_30" drop|' ] &&
	[ "$(grep -c 'type ether_addr; size 64; flags dynamic;' "$T/g3.nft")" = 2 ] && ! grep -q 'rnr1.921.*@tripped' "$T/g3.nft"
then ok "BPDU guard rules (2.5G jacks, VLANs 921 30): a BPDU on rnr1.<vid> keeps its source (bpdu_src_<vid>, 64 max) and is dropped by its own rule (a full set never lets one through); rnr1.<vid> itself never latched"
else ko "BPDU guard rules (2.5G jacks): got [$o]"; fi
if [ $NFT_OK != 2 ]; then
	nft_check "$T/g1.nft" && ok "BPDU guard (1 jack): nft -c accepts it" || { ko "BPDU guard (1 jack): nft -c"; cat "$T/nft.err"; }
	nft_check "$T/g2.nft" && ok "BPDU guard (2 jacks, 1 latched): nft -c accepts it" || { ko "BPDU guard (2 jacks): nft -c"; cat "$T/nft.err"; }
	nft_check "$T/g3.nft" && ok "BPDU guard (2.5G jacks on 2 VLANs): nft -c accepts it" || { ko "BPDU guard (2.5G jacks): nft -c"; cat "$T/nft.err"; }
fi
# 4d. the BPDU guard in a kernel (user + network namespace, veth): a BPDU from
# the jack moves its counter and latches it, after which even a plain frame
# from it is dropped; control: the same frames from a jack not in the guard
# pass. SKIP (never PASS) where namespaces, veth or python are missing.
if [ $NFT_OK != 2 ] && command -v python3 >/dev/null 2>&1; then
	sed 's/rnr1/ja/g; s/rnr0\.921/tk/g; s/rnr0_921/tk/g' "$T/g1.nft" > "$T/gk.nft"
	cat > "$T/gk.sh" <<-EOF
	set -e
	ip link add brwifi1 type bridge stp_state 0
	ip link add ja type veth peer name xa
	ip link add jc type veth peer name xc
	ip link add tk type veth peer name xt
	for i in ja jc tk; do ip link set \$i master brwifi1; done
	for i in brwifi1 ja xa jc xc tk xt; do ip link set \$i up; done
	${NFT:-/sbin/nft} -f "$T/gk.nft"
	python3 -I "$T/gk.py"
	${NFT:-/sbin/nft} list counters table bridge gt_be98_lan_guard | tr -d '\n\t' ; echo
	${NFT:-/sbin/nft} list set bridge gt_be98_lan_guard tripped | tr -d '\n\t' ; echo
	EOF
	cat > "$T/gk.py" <<-'EOF'
	import socket, time
	def tx(dev, frames):
	    s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW); s.bind((dev, 0))
	    for f in frames: s.send(f)
	def rx_on(dev):
	    s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x88b5)); s.bind((dev, 0)); s.settimeout(0.5); return s
	def got(s, mark):
	    n = 0
	    try:
	        while True:
	            if mark in s.recv(2048): n += 1
	    except socket.timeout: pass
	    return n
	bpdu = bytes.fromhex("0180c2000000020000000a010026424203") + b"\0" * 35
	def plain(src, mark): return bytes.fromhex("ffffffffffff" + src + "88b5") + mark + b"\0" * 40
	r = rx_on("xt")
	tx("xc", [bpdu, plain("020000000c01", b"CTL1")])     # control jack: not guarded
	print("control", got(r, b"CTL1"))
	tx("xa", [plain("020000000a01", b"PRE1")])            # guarded jack before any BPDU
	print("before", got(r, b"PRE1"))
	tx("xa", [bpdu]); time.sleep(0.2)
	tx("xa", [plain("020000000a01", b"POST")])            # after: latched
	print("after", got(r, b"POST"))
	EOF
	if unshare -rn sh "$T/gk.sh" > "$T/gk.out" 2>&1; then
		o=$(tr '\n' '|' < "$T/gk.out")
		case "$o" in
		"control 1|before 1|after 0|"*"bpdu_in_ja {packets 1 "*"bpdu_out_tk {packets 1 "*'elements = { "ja" }'*)
			ok "BPDU guard in a kernel: the jack forwards, a BPDU latches it (counter 1), then it is cut; the unguarded control jack still forwards, and its BPDU never reaches the trunk (egress counter 1)" ;;
		*) ko "BPDU guard in a kernel: [$o]" ;;
		esac
	else
		case "$(cat "$T/gk.out")" in
		*"Operation not supported"*|*"not permitted"*|*"Unknown device type"*) echo "SKIP BPDU guard in a kernel: $(head -n1 "$T/gk.out")" ;;
		*) ko "BPDU guard in a kernel: the namespace setup failed: $(tr '\n' ' ' < "$T/gk.out")" ;;
		esac
	fi
else
	echo "SKIP BPDU guard in a kernel: no nft/unshare/python3"
fi
# 4d'. the 2.5G jacks' guard in a kernel: jv stands for rnr1.921 (the jacks
# of VLAN 921), tk for the trunk VLAN. A BPDU from jv is dropped (never
# reaches the trunk), counted, its source kept in bpdu_src_921; jv itself is
# NOT latched (a plain frame still forwards: the switch cuts the jack, not
# the VLAN). Then gt-be98-netguard reads that very listing (the kernel's own
# nft output format) and latches the jacks of VLAN 921.
if [ $NFT_OK != 2 ] && command -v python3 >/dev/null 2>&1; then
	sed 's/rnr1\.921/jv/g; s/rnr0\.921/tk/g; s/rnr0_921/tk/g' "$T/g3.nft" | sed 's/rnr1\.30/jw/g; s/rnr0\.30/tw/g; s/rnr0_30/tw/g' > "$T/gj.nft"
	cat > "$T/gj.sh" <<-EOF
	set -e
	ip link add brwifi1 type bridge stp_state 0
	ip link add jv type veth peer name xv
	ip link add tk type veth peer name xt
	for i in jv tk; do ip link set \$i master brwifi1; done
	for i in brwifi1 jv xv tk xt; do ip link set \$i up; done
	${NFT:-/sbin/nft} -f "$T/gj.nft"
	python3 -I "$T/gj.py"
	${NFT:-/sbin/nft} list table bridge gt_be98_lan_guard > "$T/gj.list"
	EOF
	cat > "$T/gj.py" <<-'EOF'
	import socket, time
	def tx(dev, frames):
	    s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW); s.bind((dev, 0))
	    for f in frames: s.send(f)
	def rx_on(dev, proto):
	    s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(proto)); s.bind((dev, 0)); s.settimeout(0.5); return s
	def got(s, mark):
	    n = 0
	    try:
	        while True:
	            if mark in s.recv(2048): n += 1
	    except socket.timeout: pass
	    return n
	bpdu = bytes.fromhex("0180c2000000" "02000000a007" "0026424203") + b"BPDU" + b"\0" * 31
	def plain(src, mark): return bytes.fromhex("ffffffffffff" + src + "88b5") + mark + b"\0" * 40
	r = rx_on("xt", 0x88b5); ra = rx_on("xt", 0x0003)
	tx("xv", [plain("020000000a01", b"PRE1")]); print("pre", got(r, b"PRE1"))
	tx("xv", [bpdu]); time.sleep(0.2); print("bpdu", got(ra, b"BPDU"))
	tx("xv", [plain("020000000a01", b"POST")]); print("post", got(r, b"POST"))
	EOF
	if unshare -rn sh "$T/gj.sh" > "$T/gj.out" 2>&1; then
		o=$(tr '\n' '|' < "$T/gj.out"); l=$(tr -d '\n\t' < "$T/gj.list")
		case "$o|$l" in
		"pre 1|bpdu 0|post 1||"*"counter bpdu_in_rnr1_921 {packets 1 "*"set bpdu_src_921 {"*"02:00:00:00:a0:07"*)
			ok "2.5G jacks' guard in a kernel: the BPDU from the jacks' VLAN dropped (0 on the trunk), counted, its source 02:00:00:00:a0:07 in bpdu_src_921; the VLAN itself not cut (a plain frame forwards before and after)" ;;
		*) ko "2.5G jacks' guard in a kernel: [$o] [$l]" ;;
		esac
		# netguard reads the kernel's listing: the source, attributed (no driver: every jack of 921)
		mkdir -p "$T/ngk/bin" "$T/ngk/run" "$T/ngk/net" "$T/ngk/rtl"
		printf '#!/bin/sh\ncat "%s"\n' "$T/gj.list" > "$T/ngk/bin/nft"; printf '#!/bin/sh\nexit 0\n' > "$T/ngk/bin/logger"; chmod +x "$T/ngk/bin/"*
		printf 'guard\njack 4 brwifi1 921\njack 6 brwifi1 921\njack 7 brwifi2 30\n' > "$T/ngk/run/gt-be98-lan.applied"
		echo 0 > "$T/ngk/rtl/jack_block"; : > "$T/ngk/rtl/l2_lookup"
		: > "$T/ngk/lan.conf"
		GT_BE98_SYSNET="$T/ngk/net" GT_BE98_RUN="$T/ngk/run" GT_BE98_LAN_CONF="$T/ngk/lan.conf" GT_BE98_WIFI_L2="$T/ngk/none" \
			GT_BE98_RTL8372="$T/ngk/rtl" PATH="$T/ngk/bin:$PATH" sh "$SRC/sbin/gt-be98-netguard" --sweep 2>/dev/null
		r="$(cat "$T/ngk/run/gt-be98-lan.tripped.src" 2>/dev/null)|$(tr '\n' ' ' < "$T/ngk/run/gt-be98-lan.tripped" 2>/dev/null)|$(cat "$T/ngk/rtl/jack_block")"
		[ "$r" = "02:00:00:00:a0:07 921|jack4 jack6 |80" ] &&
			ok "netguard on the kernel's own listing: source 02:00:00:00:a0:07 on VLAN 921 read, jacks 4 and 6 (not 7 of VLAN 30) latched, jack_block 80" ||
			ko "netguard on the kernel's listing: [$r]"
	else
		case "$(cat "$T/gj.out")" in
		*"Operation not supported"*|*"not permitted"*|*"Unknown device type"*) echo "SKIP 2.5G jacks' guard in a kernel: $(head -n1 "$T/gj.out")" ;;
		*) ko "2.5G jacks' guard in a kernel: the namespace setup failed: $(tr '\n' ' ' < "$T/gj.out")" ;;
		esac
	fi
else
	echo "SKIP 2.5G jacks' guard in a kernel: no nft/unshare/python3"
fi

# 4e. the service: apply, reload, stop with fakes (ip on a fake sysfs, the
# gt-be98-l2 and nft calls logged): the guard is loaded before a jack joins,
# a reload moves a jack whose network changed and lets go of the old bridge,
# a jack with no network is not bridged, stop undoes all; an empty conf is a
# clean no-op that touches nothing
mkdir -p "$T/svc/bin" "$T/svc/net"
cat > "$T/svc/bin/ip" <<'X'
#!/bin/sh
echo "ip $*" >> "$SVCT/seq"
case "$*" in
"link set "*" master "*) mkdir -p "$SVCT/net/$3"; ln -sfn "../$5" "$SVCT/net/$3/master" ;;
"link set "*" nomaster") rm -f "$SVCT/net/$3/master" ;;
esac
exit 0
X
printf '#!/bin/sh\necho "l2 $*" >> "$SVCT/seq"\n' > "$T/svc/bin/l2"
printf '#!/bin/sh\necho "nft $*" >> "$SVCT/seq"\n[ "$1" = -c ] || [ "$1" = -f ] && cat > /dev/null\nexit 0\n' > "$T/svc/bin/nft"
printf '#!/bin/sh\necho "bridge $*" >> "$SVCT/seq"\n' > "$T/svc/bin/bridge"
printf '#!/bin/sh\necho "modprobe $*" >> "$SVCT/seq"\n' > "$T/svc/bin/modprobe"
printf '#!/bin/sh\necho "rmmod $*" >> "$SVCT/seq"\n' > "$T/svc/bin/rmmod"
chmod +x "$T/svc/bin/"*
mkdir -p "$T/svc/net/rnr1" "$T/svc/net/rnr3"
# the service with its /sys/class/net paths pointed at the fake tree
cp "$SRC/init.d/gt-be98-lan" "$T/svc/lan"; sed -i "s|/sys/class/net/|$T/svc/net/|g" "$T/svc/lan"; SRCLAN="$T/svc/lan"
svcf() {
	(
		eerror() { echo "E $*" >> "$SVCT/seq"; }; ebegin() { :; }; eend() { return "${1:-0}"; }; ewarn() { echo "W $*" >> "$SVCT/seq"; }; einfo() { :; }
		SVCT="$T/svc"; export SVCT; PATH="$T/svc/bin:$PATH"
		LAN_CONF_FILE="$T/lan.conf" GT_BE98_L2="$T/svc/bin/l2" GT_BE98_LAN_APPLIED="$T/svc/applied" \
			GT_BE98_LAN_TRIPPED="$T/svc/tripped" GT_BE98_WIFI_L2="$T/svc/l2.conf" GT_BE98_WIFI_CONFS="$T/svc/none"
		. "$SRCLAN"
		APPLIED="$T/svc/applied"
		wifi_trunk() { echo rnr0; }
		LAN_IFACE_WAIT=0
		"$@"
	)
}
: > "$T/svc/seq"; printf 'LAN_PORTS=""\n' > "$T/lan.conf"; rm -f "$T/svc/applied"
svcf start; r=$?
if [ $r = 0 ] && [ ! -s "$T/svc/seq" ] && [ -f "$T/svc/applied" ] && [ ! -s "$T/svc/applied" ]; then
	ok "empty conf: start rc 0, no command at all (no module, no bridge, no nft), an empty applied file"
else ko "empty conf: rc $r, seq [$(tr '\n' '|' < "$T/svc/seq")]"; fi
: > "$T/svc/seq"; cp "$T/old.conf" "$T/lan.conf"; rm -f "$T/svc/applied"
svcf start; r=$?
if [ $r = 0 ] && [ ! -s "$T/svc/seq" ] && [ -f "$T/svc/applied" ] && [ ! -s "$T/svc/applied" ]; then
	ok "older-image conf (keys absent): start rc 0, no command at all, an empty applied file"
else ko "older-image conf start: rc $r, seq [$(tr '\n' '|' < "$T/svc/seq")]"; fi
: > "$T/svc/seq"; svcf reload
[ ! -s "$T/svc/seq" ] || [ "$(cat "$T/svc/seq")" = "" ] && ok "older-image conf: reload runs no command" || ko "older-image conf reload: [$(tr '\n' '|' < "$T/svc/seq")]"
printf 'LAN_PORTS=""\n' > "$T/lan.conf"
: > "$T/svc/seq"; svcf stop
[ ! -s "$T/svc/seq" ] && ok "empty conf: stop runs no command" || ko "empty conf stop: [$(tr '\n' '|' < "$T/svc/seq")]"
# the 2.5G jacks: the driver's sysfs (a fake directory: plain files), every
# write logged as "put <attr> <value>"; PUTFAIL="<attr>:<error text>:<n>"
# makes the first n writes of <attr> fail with that text (what the shell
# prints for the driver's errno)
mkdir -p "$T/svc/rtl" "$T/svc/net/rnr2"
printf '#!/bin/sh\necho "sleep $*" >> "$SVCT/seq"\n' > "$T/svc/bin/sleep"
printf '#!/bin/sh\necho "modprobe $*" >> "$SVCT/seq"\necho "rtl8372 1 0 - Live" >> "$SVCT/modules"\n' > "$T/svc/bin/modprobe"
printf '#!/bin/sh\necho "rmmod $*" >> "$SVCT/seq"\n: > "$SVCT/modules"\n' > "$T/svc/bin/rmmod"
chmod +x "$T/svc/bin/"*
svcj() {
	(
		eerror() { echo "E $*" >> "$SVCT/seq"; }; ebegin() { :; }; eend() { return "${1:-0}"; }; ewarn() { echo "W $*" >> "$SVCT/seq"; }; einfo() { :; }
		SVCT="$T/svc"; export SVCT; PATH="$T/svc/bin:$PATH"
		LAN_CONF_FILE="$T/lan.conf" GT_BE98_L2="$T/svc/bin/l2" GT_BE98_LAN_APPLIED="$T/svc/applied" \
			GT_BE98_LAN_TRIPPED="$T/svc/tripped" GT_BE98_WIFI_L2="$T/svc/l2.conf" GT_BE98_WIFI_CONFS="$T/svc/none" \
			GT_BE98_RTL8372="$T/svc/rtl" GT_BE98_PROC_MODULES="$T/svc/modules" GT_BE98_SWITCH_WAIT=${SW:-3}
		. "$SRCLAN"
		APPLIED="$T/svc/applied"
		wifi_trunk() { echo rnr0; }
		LAN_IFACE_WAIT=0
		rtl_put() {
			echo "put $1 $2" >> "$SVCT/seq"
			if [ -n "${PUTFAIL:-}" ] && [ "${PUTFAIL%%:*}" = "$1" ]; then
				c=$(cat "$SVCT/putn" 2>/dev/null || echo 0)
				if [ "$c" -lt "${PUTFAIL##*:}" ]; then
					echo $((c + 1)) > "$SVCT/putn"; RTL_ERR="sh: line 1: printf: write error: $(echo "$PUTFAIL" | cut -d: -f2)"; return 1
				fi
			fi
			RTL_ERR=$( { printf '%s\n' "$2" > "$RTL_DIR/$1"; } 2>&1 )
		}
		"$@"
	)
}
seqf() { grep -v '^ip link set rnr[123] \(up\|down\)$\|^ip -4 addr flush\|^W \|^E ' "$T/svc/seq" | tr '\n' '|'; }
jp() { cat "$T/svc/rtl/jack_profiles"; }
rm -f "$T/svc/applied" "$T/svc/tripped" "$T/svc/putn"; : > "$T/svc/modules"
printf '4=1 5=1 6=1 7=1\n' > "$T/svc/rtl/jack_profiles"; echo 0x0 > "$T/svc/rtl/jack_block"; : > "$T/svc/rtl/l2_lookup"
printf 'WIFI_TRUNK="rnr0"\nWIFI_VLANS="brwifi7:921 brwifi8:30"\n' > "$T/svc/l2.conf"
printf 'LAN_PORT_rnr1=""\nLAN_JACK_4="native=921 tagged=none enabled=1"\nLAN_JACK_5="native=55"\nLAN_JACK_6="native=921"\nLAN_JACK_7="native=30"\nLAN_PORT_rnr2="native=30"\n' > "$T/lan.conf"
: > "$T/svc/seq"; svcj start; r=$?
o=$(seqf)
[ "$o" = "modprobe rtl8372|put jack_profiles 4=921 5=off 6=921 7=30|put jack_block 0|nft -c -f -|nft -f -|l2 up lan brwifi8 rnr0 30 rnr1|l2 up lan brwifi7 rnr0 921 rnr1|ip link set rnr2 master brwifi8|" ] &&
	ok "start: the module, the WHOLE set (jack 5 off: no network on VLAN 55), the latch (0), the guard, then each network bridge ONCE with rnr1 (rnr1.<vid>), then the bare rnr2" ||
	ko "start sequence: [$o]"
grep -q '^E LAN_JACK_5: no network on VLAN 55.*jack 5 off' "$T/svc/seq" && [ $r = 0 ] && ok "start: jack 5 refused (logged), rc 0 (a Wi-Fi reload retries)" || ko "start: jack 5 / rc $r"
check_applied() { if [ "$(tr '\n' '|' < "$T/svc/applied")" = "$1" ]; then ok "applied: $1"; else ko "applied: want [$1] got [$(tr '\n' '|' < "$T/svc/applied")]"; fi; }
check_applied "module rtl8372|jacks 4=921 5=off 6=921 7=30|guard|vport rnr2 brwifi8 30|jack 4 brwifi7 921|jack 6 brwifi7 921|jack 7 brwifi8 30|"
[ "$(jp)" = "4=921 5=off 6=921 7=30" ] && ok "the driver holds 4=921 5=off 6=921 7=30" || ko "driver set: $(jp)"
# reload, nothing changed: the same set again (a no-op in the driver), the bridges re-asserted
: > "$T/svc/seq"; svcj reload
[ "$(seqf)" = "put jack_profiles 4=921 5=off 6=921 7=30|put jack_block 0|nft -c -f -|nft -f -|l2 up lan brwifi8 rnr0 30 rnr1|l2 up lan brwifi7 rnr0 921 rnr1|" ] &&
	ok "reload unchanged: the same set (no-op), the bridges re-asserted, no module load, no move" || ko "reload unchanged: [$(seqf)]"
# the web UI moves jack 7 to VLAN 921: brwifi8 keeps rnr2 but no longer rnr1.30
printf 'LAN_PORT_rnr1=""\nLAN_JACK_4="native=921"\nLAN_JACK_6="native=921"\nLAN_JACK_7="native=921"\nLAN_PORT_rnr2="native=30"\n' > "$T/lan.conf"
: > "$T/svc/seq"; svcj reload
[ "$(seqf)" = "put jack_profiles 4=921 5=off 6=921 7=921|put jack_block 0|nft -c -f -|nft -f -|l2 up lan brwifi8 rnr0 30|l2 up lan brwifi7 rnr0 921 rnr1|" ] &&
	ok "reload, jack 7 moved to VLAN 921: the switch first, then brwifi8 re-stated WITHOUT rnr1 (gt-be98-l2 removes rnr1.30), brwifi7 with it" || ko "reload jack 7 moved: [$(seqf)]"
# the network of 921 moves to brwifi9: the jacks' bridge is let go, the new one taken
printf 'WIFI_TRUNK="rnr0"\nWIFI_VLANS="brwifi9:921 brwifi8:30"\n' > "$T/svc/l2.conf"
: > "$T/svc/seq"; svcj reload
[ "$(seqf)" = "put jack_profiles 4=921 5=off 6=921 7=921|put jack_block 0|l2 down lan brwifi7|nft -c -f -|nft -f -|l2 up lan brwifi8 rnr0 30|l2 up lan brwifi9 rnr0 921 rnr1|" ] &&
	ok "reload, VLAN 921's network now brwifi9: brwifi7 let go, brwifi9 taken with rnr1" || ko "reload network moved: [$(seqf)]"
# the BPDU guard latched jack 6 (gt-be98-netguard): reload keeps its VLAN, writes the latch
echo jack6 > "$T/svc/tripped"; echo 0x0 > "$T/svc/rtl/jack_block"
: > "$T/svc/seq"; svcj reload
[ "$(cat "$T/svc/rtl/jack_block")" = 64 ] && grep -q '^put jack_profiles 4=921 5=off 6=921 7=921$' "$T/svc/seq" && grep -q '^W 2.5G jacks latched off by the BPDU guard (jack_block 64)' "$T/svc/seq" &&
	ok "latched jack 6: the set unchanged, jack_block 64 written after it (the latch survives a module reload: re-written at every set)" || ko "latch: block $(cat "$T/svc/rtl/jack_block") [$(tr '\n' '|' < "$T/svc/seq")]"
# a latch that cannot be written: the latched jack written off instead
: > "$T/svc/seq"; rm -f "$T/svc/putn"; PUTFAIL="jack_block:Input/output error:9" svcj reload
[ "$(jp)" = "4=921 5=off 6=off 7=921" ] && ok "jack_block refused (-EIO): jack 6 written off instead (never left forwarding)" || ko "block refused: $(jp) [$(tr '\n' '|' < "$T/svc/seq")]"
rm -f "$T/svc/tripped" "$T/svc/putn"
# the configurator still running: -EAGAIN retried, then written
: > "$T/svc/seq"; PUTFAIL="jack_profiles:Resource temporarily unavailable:2" svcj reload
[ "$(grep -c '^sleep 1$' "$T/svc/seq") $(grep -c '^put jack_profiles' "$T/svc/seq") $(jp)" = "2 3 4=921 5=off 6=921 7=921" ] &&
	ok "-EAGAIN twice: retried after 1 s each, written on the third try" || ko "EAGAIN: [$(tr '\n' '|' < "$T/svc/seq")]"
rm -f "$T/svc/putn"; : > "$T/svc/seq"; PUTFAIL="jack_profiles:Resource temporarily unavailable:99" SW=3 svcj reload; r=$?
[ "$(grep -c '^sleep 1$' "$T/svc/seq") $r" = "3 1" ] && grep -q '^E the RTL8372 is not configured after 3 s' "$T/svc/seq" && ! grep -q 'l2 up .* rnr1$' "$T/svc/seq" &&
	ok "-EAGAIN for good: bounded (3 s here, 20 by default), rc 1, no jack bridged (no rnr1.<vid>)" || ko "EAGAIN bound: rc $r [$(tr '\n' '|' < "$T/svc/seq")]"
rm -f "$T/svc/putn"; svcj reload; grep -q '^jack 4 brwifi9 921$' "$T/svc/applied" && ok "control: a reload once the switch answers bridges the jacks again" || ko "re-bridge after EAGAIN"
rm -f "$T/svc/putn"; : > "$T/svc/seq"; PUTFAIL="jack_profiles:Invalid argument:1" svcj reload; r=$?
[ "$(grep -c '^sleep' "$T/svc/seq") $r" = "0 1" ] && grep -q "^E the RTL8372 refused jack_profiles '4=921 5=off 6=921 7=921': Invalid argument" "$T/svc/seq" &&
	! grep -q '^jack ' "$T/svc/applied" && grep -q '^vport rnr2 ' "$T/svc/applied" && grep -q '^l2 down lan brwifi9' "$T/svc/seq" &&
	ok "control: -EINVAL is not retried; rc 1; the jacks' bridge let go, the bare rnr2 kept" || ko "EINVAL: rc $r [$(tr '\n' '|' < "$T/svc/seq")] applied [$(tr '\n' '|' < "$T/svc/applied")]"
rm -f "$T/svc/putn"; : > "$T/svc/seq"; svcj reload
grep -q '^l2 up lan brwifi9 rnr0 921 rnr1$' "$T/svc/seq" && ok "control: the next reload bridges the jacks again" || ko "re-bridge: [$(tr '\n' '|' < "$T/svc/seq")]"
# the real rtl_put: an error the shell reports (here a directory) is captured, not retried
r=$(
	eerror() { echo "E $*"; }; ewarn() { :; }
	LAN_CONF_FILE="$T/lan.conf"; . "$SRC/init.d/gt-be98-lan"
	mkdir -p "$T/rtlx/jack_profiles"; RTL_GLOB="$T/rtlx"; SWITCH_WAIT=2
	sleep() { echo slept; }
	jacks_write "4=off 5=off 6=off 7=off"; echo "rc=$?"
)
case "$r" in "E the RTL8372 refused jack_profiles '4=off 5=off 6=off 7=off': Is a directory"*"rc=1") ok "the real rtl_put: the shell's error text captured (Is a directory), refused at once, no sleep" ;; *) ko "real rtl_put: [$r]" ;; esac
# no driver bound and the module not loaded (LAN_SWITCH_MONITOR=no): refused at once
mv "$T/svc/rtl" "$T/svc/rtl.off"; : > "$T/svc/modules"; : > "$T/svc/seq"; svcj reload; r=$?
[ "$(grep -c '^sleep' "$T/svc/seq") $r" = "0 1" ] && grep -q '^E rtl8372 is not loaded' "$T/svc/seq" && ok "no driver and no module: refused at once, rc 1" || ko "no driver: rc $r [$(tr '\n' '|' < "$T/svc/seq")]"
mv "$T/svc/rtl.off" "$T/svc/rtl"; echo "rtl8372 1 0 - Live" > "$T/svc/modules"; svcj reload >/dev/null
# stop: every jack off FIRST, then the guard, the module, the bridges let go
: > "$T/svc/seq"; svcj stop
o=$(seqf)
[ "$o" = "put jack_profiles 4=off 5=off 6=off 7=off|put jack_block 0|nft delete table bridge gt_be98_lan_guard|ip link set rnr2 nomaster|rmmod rtl8372|l2 down lan brwifi8|l2 down lan brwifi9|" ] &&
	ok "stop: the four jacks off in the switch BEFORE anything else (no jack forwards into a bridge losing rnr1.<vid>), the guard, rnr2 out, the module, each bridge let go once" || ko "stop: [$o]"
[ ! -e "$T/svc/applied" ] && [ ! -e "$T/svc/tripped" ] && ok "stop: applied state and the latch cleared" || ko "stop: state left"
# restart clears the latch: stop + start (start removes it too)
echo jack6 > "$T/svc/tripped"; echo "x 1" > "$T/svc/tripped.src"
: > "$T/svc/seq"; svcj start
[ ! -e "$T/svc/tripped" ] && [ ! -e "$T/svc/tripped.src" ] && grep -q '^put jack_block 0$' "$T/svc/seq" &&
	ok "start (restart's second half): the latch and the seen sources cleared, jack_block 0 written" || ko "start clears: [$(tr '\n' '|' < "$T/svc/seq")]"
svcj stop
# the routed LAN (LAN_PORTS=rnr1): every jack untagged on bare rnr1 (VLAN 1); stop: off
printf 'LAN_PORTS="rnr1"\nLAN_PORT_rnr1=""\n' > "$T/lan.conf"; echo "4=off 5=off 6=off 7=off" > "$T/svc/rtl/jack_profiles"
: > "$T/svc/seq"; svcj start
[ "$(jp)" = "4=1 5=1 6=1 7=1" ] && grep -q '^jacks 4=1 5=1 6=1 7=1$' "$T/svc/applied" && ! grep -q '^l2 ' "$T/svc/seq" &&
	ok "LAN_PORTS=rnr1: the set 4=1 5=1 6=1 7=1 (a former VLAN set undone), no network bridge" || ko "routed rnr1: $(jp) [$(tr '\n' '|' < "$T/svc/seq")]"
: > "$T/svc/seq"; svcj reload
! grep -q '^put jack_profiles' "$T/svc/seq" && ok "LAN_PORTS=rnr1: reload never touches the set" || ko "routed reload: [$(tr '\n' '|' < "$T/svc/seq")]"
svcj stop; [ "$(jp)" = "4=off 5=off 6=off 7=off" ] && ok "LAN_PORTS=rnr1: stop writes the jacks off" || ko "routed stop: $(jp)"
# RC9's conf (LAN_PORT_rnr1 only): the migration, all four jacks on its VLAN
printf 'LAN_PORT_rnr1="native=921 tagged=none enabled=1"\n' > "$T/lan.conf"
: > "$T/svc/seq"; svcj start
[ "$(jp)" = "4=921 5=921 6=921 7=921" ] && grep -q '^l2 up lan brwifi9 rnr0 921 rnr1$' "$T/svc/seq" && ! grep -q 'ip link set rnr1 master' "$T/svc/seq" &&
	ok "RC9 conf (LAN_PORT_rnr1): all four jacks on VLAN 921 through rnr1.921, bare rnr1 never enslaved" || ko "migration: $(jp) [$(tr '\n' '|' < "$T/svc/seq")]"
svcj stop

# 4f. tagged VLANs on the 2.5G jacks (LAN_JACK_<n> tagged=none|all|<list>)
# parse: <expect rc> <conf lines> <expected "<n>=<native>[<tagged>] " words> [an error text expected]
jt_case() {
	printf "$2\n" > "$T/lan.conf"
	: > "$T/jk.err"
	r=$(
		eerror() { echo "E $*" >> "$T/jk.err"; }; ebegin() { :; }; eend() { :; }; ewarn() { echo "W $*" >> "$T/jk.err"; }
		LAN_CONF_FILE="$T/lan.conf"
		. "$SRC/init.d/gt-be98-lan"
		wifi_trunk() { echo rnr0; }
		load_conf || exit 1
		for n in $JACKS; do eval "printf '%s=%s[%s] ' $n \$JNATIVE_$n \"\$JTAGGED_$n\""; done
	)
	rc=$?; [ $rc -ne 0 ] && rc=1
	e=ok; [ -z "${4:-}" ] || grep -q -- "$4" "$T/jk.err" || e="no error '$4' in [$(tr '\n' '|' < "$T/jk.err")]"
	if [ "$rc" = "$1" ] && [ "$r" = "$3" ] && [ "$e" = ok ]; then ok "tagged jacks rc=$1: $(printf "$2" | tr '\n' ' ') -> [$3]${4:+ ($4)}"
	else ko "tagged jacks want rc=$1 [$3] got rc=$rc [$r] $e: $2"; fi
}
jt_case 0 'LAN_JACK_6="native=30 tagged=40,921 enabled=1"' "6=30[40 921] "
jt_case 0 'LAN_JACK_6="native=30 tagged=921,40"' "6=30[921 40] "		# as written (the set sorts them)
jt_case 0 'LAN_JACK_6="native=30 tagged=all"' "6=30[all] "
jt_case 0 'LAN_JACK_6="native=30 tagged=none"' "6=30[] "
jt_case 0 'LAN_JACK_6="native=30"' "6=30[] "					# no tagged= is none
jt_case 0 'LAN_JACK_6="native=30 tagged=40 enabled=0"' ""			# disabled: off, tags and all
jt_case 0 'LAN_PORT_rnr1="native=921 tagged=30"' "4=921[30] 5=921[30] 6=921[30] 7=921[30] "	# RC9 migration: the profile of all four
for b in 'tagged=30' 'tagged=1' 'tagged=0' 'tagged=4095' 'tagged=040' 'tagged=40,40' 'tagged=40,' 'tagged=,40' 'tagged=40,,50' 'tagged=' 'tagged=all,40' 'tagged=none,40' 'tagged=40;50'; do
	jt_case 0 "LAN_JACK_6=\"native=30 $b\"\nLAN_JACK_4=\"native=921\"" "4=921[] " "jack 6 off"
done
l=$(seq -s, 100 131); jt_case 0 "LAN_JACK_6=\"native=30 tagged=$l\"" "6=30[$(seq -s' ' 100 131)] "	# 32: the cap
l=$(seq -s, 100 132); jt_case 0 "LAN_JACK_6=\"native=30 tagged=$l\"\nLAN_JACK_4=\"native=921\"" "4=921[] " "33 tagged VLANs refused (at most 32 per jack)"
vp_case 1 'LAN_PORT_rnr3="native=30 tagged=40"'					# never on a bare port

# resolution against the networks: <native> <JTAGGED> -> "rc=<rc> [JT]"
jtr() {
	(
		eerror() { echo "E $*" >> "$T/jtr.err"; }
		LAN_CONF_FILE="$T/lan.conf"; GT_BE98_WIFI_L2="$T/l2t.conf"; GT_BE98_WIFI_CONFS="$T/wifi-ap $T/wifi"
		. "$SRC/init.d/gt-be98-lan"
		JT=; jack_tagged 6 "$1" "$2"; echo "rc=$? [$JT]"
	)
}
jtr_case() {
	: > "$T/jtr.err"; r=$(jtr "$1" "$2")
	e=ok; [ -z "${5:-}" ] || grep -q -- "$5" "$T/jtr.err" || e="no error '$5' in [$(tr '\n' '|' < "$T/jtr.err")]"
	[ -n "${5:-}" ] || [ ! -s "$T/jtr.err" ] || e="unexpected error [$(tr '\n' '|' < "$T/jtr.err")]"
	if [ "$r" = "$3" ] && [ "$e" = ok ]; then ok "tagged resolution: native $1 tagged '$2' -> $3 ($4)"
	else ko "tagged resolution: native $1 tagged '$2': want [$3] got [$r] $e ($4)"; fi
}
rm -f "$T/wifi-ap" "$T/wifi"
printf 'WIFI_TRUNK="rnr0"\nWIFI_VLANS="brwifi7:921 brwifi8:30 brwifi9:40 brwifi1:1 brwifi10:5 brwifi3:921"\n' > "$T/l2t.conf"
jtr_case 30 all "rc=0 [6:brwifi10:5 6:brwifi9:40 6:brwifi7:921]" "every network but VLAN 1 and the native, ascending, a VID once (its first network)"
jtr_case 921 all "rc=0 [6:brwifi10:5 6:brwifi8:30 6:brwifi9:40]" "another native: 30 in, 921 out"
jtr_case 30 "921 40" "rc=0 [6:brwifi9:40 6:brwifi7:921]" "a list: each to its network, ascending"
jtr_case 30 "40 77" "rc=1 [6:brwifi9:40]" "a listed VLAN with no network: not carried, the others are" "tagged VLAN 77 has no network"
jtr_case 30 "" "rc=0 []" "none"
printf 'WIFI_VLANS="brwifi8:30"\n' > "$T/l2t.conf"
jtr_case 30 all "rc=0 []" "all with no other network: nothing tagged"
printf 'WIFI_VLANS="brwifi8:30 %s"\n' "$(for v in $(seq 100 131); do printf 'brwifi%s:%s ' $v $v; done)" > "$T/l2t.conf"
r=$(jtr 30 all); [ "$(echo "$r" | tr ' ' '\n' | grep -c '^\[\{0,1\}6:brwifi')" = 32 ] && case "$r" in rc=0*) true ;; *) false ;; esac &&
	ok "tagged=all over 32 other networks: all 32 carried" || ko "all x32: [$r]"
printf 'WIFI_VLANS="brwifi8:30 %s"\n' "$(for v in $(seq 100 132); do printf 'brwifi%s:%s ' $v $v; done)" > "$T/l2t.conf"
jtr_case 30 all "rc=1 []" "33 other networks: more than the driver takes, the native only" "tagged=all is 33 VLANs, more than 32"
# Wi-Fi not running: the configured network list, as for the native VLAN
rm -f "$T/l2t.conf"
printf 'WIFI_NETWORKS=%s\nWIFI_VLANS=""\n' "$T/networks.conf" > "$T/wifi"
jtr_case 30 all "rc=0 [6:brwifi7:921]" "Wi-Fi stopped: the network list (921, 30; the vlan= outside a network ignored)"
printf 'WIFI_NETWORKS=""\nWIFI_VLANS="brwifi3:31"\n' > "$T/wifi-ap"
jtr_case 30 all "rc=0 [6:brwifi3:31]" "the web UI file wins as a whole, as for the native VLAN"
rm -f "$T/wifi-ap" "$T/wifi"

# the service with tagged jacks: the whole set with "+<t>,..", every VID a
# jack carries bridged with rnr1 (gt-be98-l2 makes rnr1.<vid>), the guard
# on every rnr1.<vid>, the applied state, a reload re-resolving all
printf '#!/bin/sh\necho "nft $*" >> "$SVCT/seq"\ncase "$1" in -f) cat > "$SVCT/nft.in" ;; -c) cat > /dev/null ;; esac\nexit 0\n' > "$T/svc/bin/nft"
chmod +x "$T/svc/bin/nft"
rm -f "$T/svc/applied" "$T/svc/tripped" "$T/svc/putn"; : > "$T/svc/modules"
printf 'WIFI_TRUNK="rnr0"\nWIFI_VLANS="brwifi9:921 brwifi8:30 brwifi5:40"\n' > "$T/svc/l2.conf"
printf 'LAN_PORT_rnr1=""\nLAN_JACK_4="native=40 tagged=none enabled=1"\nLAN_JACK_6="native=30 tagged=921,40 enabled=1"\n' > "$T/lan.conf"
: > "$T/svc/seq"; svcj start; r=$?
o=$(seqf)
[ $r = 0 ] && [ "$o" = "modprobe rtl8372|put jack_profiles 4=40 5=off 6=30+40,921 7=off|put jack_block 0|nft -c -f -|nft -f -|l2 up lan brwifi5 rnr0 40 rnr1|l2 up lan brwifi8 rnr0 30 rnr1|l2 up lan brwifi9 rnr0 921 rnr1|" ] &&
	ok "tagged start: the set 6=30+40,921 (sorted, the driver's syntax), then each bridge of a VID any jack carries ONCE with rnr1 (40: jack 4's native and jack 6's tag), 921 a tag only" ||
	ko "tagged start: rc $r [$o]"
check_applied "module rtl8372|jacks 4=40 5=off 6=30+40,921 7=off|guard|jack 4 brwifi5 40|jack 6 brwifi8 30|jacktag 6 brwifi5 40|jacktag 6 brwifi9 921|"
[ "$(jp)" = "4=40 5=off 6=30+40,921 7=off" ] && ok "the driver holds 4=40 5=off 6=30+40,921 7=off" || ko "driver set: $(jp)"
g=$(sed -n 's/^[[:space:]]*iifname "\(rnr1\.[0-9]*\)" ether daddr 01:80:c2:00:00:00 counter.*/\1/p' "$T/svc/nft.in" | tr '\n' ' ')
[ "$g" = "rnr1.40 rnr1.30 rnr1.921 " ] && grep -q 'set bpdu_src_921 {' "$T/svc/nft.in" && grep -q 'counter bpdu_out_rnr0_921 { }' "$T/svc/nft.in" &&
	ok "tagged start: the BPDU guard on every rnr1.<vid> a jack carries, the tag-only 921 included (its source set, no BPDU out on rnr0.921)" ||
	ko "tagged guard: [$g] $(grep -c bpdu_src_ "$T/svc/nft.in")"
# Wi-Fi adds a network (VLAN 50) and the jack asks for all: the reload re-resolves
printf 'WIFI_TRUNK="rnr0"\nWIFI_VLANS="brwifi9:921 brwifi8:30 brwifi5:40 brwifi6:50"\n' > "$T/svc/l2.conf"
printf 'LAN_PORT_rnr1=""\nLAN_JACK_4="native=40 tagged=none enabled=1"\nLAN_JACK_6="native=30 tagged=all enabled=1"\n' > "$T/lan.conf"
: > "$T/svc/seq"; svcj reload
[ "$(seqf)" = "put jack_profiles 4=40 5=off 6=30+40,50,921 7=off|put jack_block 0|nft -c -f -|nft -f -|l2 up lan brwifi5 rnr0 40 rnr1|l2 up lan brwifi8 rnr0 30 rnr1|l2 up lan brwifi6 rnr0 50 rnr1|l2 up lan brwifi9 rnr0 921 rnr1|" ] &&
	ok "tagged=all: every network but the native (40 50 921), brwifi6 taken with rnr1" || ko "tagged=all reload: [$(seqf)]"
# the network of 921 goes away (gt-be98-wifi's reload then reloads this service): 921 is no longer carried
printf 'WIFI_TRUNK="rnr0"\nWIFI_VLANS="brwifi8:30 brwifi5:40 brwifi6:50"\n' > "$T/svc/l2.conf"
: > "$T/svc/seq"; svcj reload
[ "$(seqf)" = "put jack_profiles 4=40 5=off 6=30+40,50 7=off|put jack_block 0|l2 down lan brwifi9|nft -c -f -|nft -f -|l2 up lan brwifi5 rnr0 40 rnr1|l2 up lan brwifi8 rnr0 30 rnr1|l2 up lan brwifi6 rnr0 50 rnr1|" ] &&
	! grep -q 921 "$T/svc/applied" && ok "a network gone: tagged=all drops 921 from the switch first, then brwifi9 let go" || ko "network gone: [$(seqf)] [$(tr '\n' '|' < "$T/svc/applied")]"
# a listed VLAN with no network: not carried, logged, rc 1, the jack's other VLANs kept
printf 'LAN_PORT_rnr1=""\nLAN_JACK_4="native=40 tagged=none enabled=1"\nLAN_JACK_6="native=30 tagged=50,77 enabled=1"\n' > "$T/lan.conf"
: > "$T/svc/seq"; svcj reload; r=$?
[ $r = 1 ] && [ "$(jp)" = "4=40 5=off 6=30+50 7=off" ] && grep -q '^E LAN_JACK_6: tagged VLAN 77 has no network' "$T/svc/seq" &&
	ok "a listed VLAN with no network: 77 not carried (logged, rc 1), 6=30+50 kept" || ko "listed VLAN without network: rc $r $(jp) [$(tr '\n' '|' < "$T/svc/seq")]"
# a tag shared with a bare port's native: one bridge, rnr2 and rnr1.50 in it
printf 'LAN_PORT_rnr1=""\nLAN_JACK_6="native=30 tagged=50"\nLAN_PORT_rnr2="native=50"\n' > "$T/lan.conf"
: > "$T/svc/seq"; svcj reload
o=$(seqf)
case "$o" in *"l2 up lan brwifi6 rnr0 50 rnr1|"*"ip link set rnr2 master brwifi6|"*) ok "jack 6's tag 50 = rnr2's native: brwifi6 once with rnr1 (rnr1.50) and rnr2" ;; *) ko "shared VID: [$o]" ;; esac
[ "$(grep -c '^l2 up lan brwifi6 ' "$T/svc/seq")" = 1 ] && ok "... one gt-be98-l2 call for it" || ko "shared VID calls: [$o]"
# tagged back to none: the tag-only bridge brwifi6 keeps rnr2 but no longer rnr1.50
printf 'LAN_PORT_rnr1=""\nLAN_JACK_6="native=30 tagged=none"\nLAN_PORT_rnr2="native=50"\n' > "$T/lan.conf"
: > "$T/svc/seq"; svcj reload
[ "$(seqf)" = "put jack_profiles 4=off 5=off 6=30 7=off|put jack_block 0|nft -c -f -|nft -f -|l2 up lan brwifi6 rnr0 50|l2 up lan brwifi8 rnr0 30 rnr1|" ] &&
	! grep -q '^jacktag ' "$T/svc/applied" && ok "tagged=none again: the set 6=30, brwifi6 re-stated WITHOUT rnr1 (rnr1.50 removed), no jacktag line" || ko "tagged none: [$(seqf)]"
# a latched jack with tags whose jack_block cannot be written: written off, tags and all
printf 'LAN_PORT_rnr1=""\nLAN_JACK_4="native=40"\nLAN_JACK_6="native=30 tagged=40"\n' > "$T/lan.conf"
echo jack6 > "$T/svc/tripped"
: > "$T/svc/seq"; rm -f "$T/svc/putn"; PUTFAIL="jack_block:Input/output error:9" svcj reload
[ "$(jp)" = "4=40 5=off 6=off 7=off" ] && ok "latched jack 6 with tagged VLANs, jack_block refused: jack 6 written off (no tag left forwarding)" || ko "latched tagged: $(jp)"
rm -f "$T/svc/tripped" "$T/svc/putn"
# stop: the jacks off first, every bridge let go once, the tag-only ones included
printf 'LAN_PORT_rnr1=""\nLAN_JACK_4="native=40"\nLAN_JACK_6="native=30 tagged=921"\n' > "$T/lan.conf"
printf 'WIFI_TRUNK="rnr0"\nWIFI_VLANS="brwifi9:921 brwifi8:30 brwifi5:40"\n' > "$T/svc/l2.conf"
svcj reload > /dev/null; : > "$T/svc/seq"; svcj stop
o=$(seqf)
[ "$o" = "put jack_profiles 4=off 5=off 6=off 7=off|put jack_block 0|nft delete table bridge gt_be98_lan_guard|rmmod rtl8372|l2 down lan brwifi5|l2 down lan brwifi8|l2 down lan brwifi9|" ] &&
	ok "tagged stop: the jacks off first, then each bridge let go once, brwifi9 (921, a tag only) too" || ko "tagged stop: [$o]"

# netguard on a BPDU from a jack's TAGGED VLAN (rnr1.40, jack 6 carries 40
# tagged): attributed over the jacks CARRYING 40 (no driver answer here:
# all of them = 4 native, 6 tagged); control: without the jacktag line,
# jack 4 only
for c in tag ctl; do
	rm -rf "$T/ngt"; mkdir -p "$T/ngt/bin" "$T/ngt/run" "$T/ngt/net" "$T/ngt/rtl"
	printf 'table bridge gt_be98_lan_guard {\n\tcounter bpdu_in_rnr1_40 {\n\t\tpackets 1 bytes 60\n\t}\n\tset bpdu_src_40 {\n\t\ttype ether_addr\n\t\tsize 64\n\t\tflags dynamic\n\t\telements = { 02:00:00:00:a0:08 }\n\t}\n}\n' > "$T/ngt/list"
	printf '#!/bin/sh\ncat "%s"\n' "$T/ngt/list" > "$T/ngt/bin/nft"; printf '#!/bin/sh\nexit 0\n' > "$T/ngt/bin/logger"; chmod +x "$T/ngt/bin/"*
	printf 'guard\njack 4 brwifi5 40\njack 6 brwifi8 30\n' > "$T/ngt/run/gt-be98-lan.applied"
	[ $c = tag ] && echo 'jacktag 6 brwifi5 40' >> "$T/ngt/run/gt-be98-lan.applied"
	echo 0 > "$T/ngt/rtl/jack_block"; : > "$T/ngt/rtl/l2_lookup"; : > "$T/ngt/lan.conf"
	GT_BE98_SYSNET="$T/ngt/net" GT_BE98_RUN="$T/ngt/run" GT_BE98_LAN_CONF="$T/ngt/lan.conf" GT_BE98_WIFI_L2="$T/ngt/none" \
		GT_BE98_RTL8372="$T/ngt/rtl" PATH="$T/ngt/bin:$PATH" sh "$SRC/sbin/gt-be98-netguard" --sweep 2>/dev/null
	r="$(tr '\n' ' ' < "$T/ngt/run/gt-be98-lan.tripped" 2>/dev/null)|$(cat "$T/ngt/rtl/jack_block")"
	if [ $c = tag ]; then
		[ "$r" = "jack4 jack6 |80" ] && ok "netguard, BPDU on rnr1.40 (jack 6's tag): jacks 4 and 6 latched (both carry 40), jack_block 80" || ko "netguard tagged BPDU: [$r]"
	else
		[ "$r" = "jack4 |16" ] && ok "control: without jack 6's jacktag line only jack 4 (40 native) is latched" || ko "netguard tagged control: [$r]"
	fi
done

echo "gt-be98-lan-test: $pass ok, $fail failed"
[ $fail -eq 0 ]

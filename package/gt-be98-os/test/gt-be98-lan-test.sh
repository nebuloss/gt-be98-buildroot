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
vp_case 0 'LAN_PORT_rnr1="native=921 tagged=none"' "ports=[rnr1] rnr1=921 "
vp_case 0 'LAN_PORT_rnr1="native=921"' "ports=[rnr1] rnr1=921 "
vp_case 0 'LAN_PORT_rnr1="native=921"\nLAN_PORT_rnr3="native=30"' "ports=[rnr1 rnr3] rnr1=921 rnr3=30 "
vp_case 0 'LAN_PORT_rnr1="native=921 enabled=0"' "ports=[] "		# disabled: no jack
vp_case 0 '' "ports=[] "						# nothing at all: no error (the no-op)
vp_case 1 'LAN_PORT_rnr1="native=921 tagged=all"'			# step 1: tagged=none only
vp_case 1 'LAN_PORT_rnr1="native=921 tagged=30"'
vp_case 1 'LAN_PORT_rnr1="native=0"'
vp_case 1 'LAN_PORT_rnr1="native=4095"'
vp_case 1 'LAN_PORT_rnr1="native=0921"'
vp_case 1 'LAN_PORT_rnr1="tagged=none"'					# no native
vp_case 1 'LAN_PORT_rnr1="native=921 enabled=2"'
vp_case 1 'LAN_PORT_rnr1="native=921 foo=1"'
vp_case 1 'LAN_PORT_rnr1="native=921;reboot"'				# characters outside the profile's
vp_case 1 'LAN_PORT_rnr0="native=921"'					# the uplink, never
vp_case 1 'LAN_PORT_rnr1="native=921"\nLAN_PORTS="rnr1"'		# one or the other
vp_case 0 'LAN_PORT_rnr1="native=921"\nLAN_PORTS="rnr2"' "ports=[rnr1] rnr1=921 "
TRUNK=rnr1 vp_case 1 'LAN_PORT_rnr1="native=921"'			# the Wi-Fi trunk port
TRUNK=rnr2 vp_case 0 'LAN_PORT_rnr1="native=921"' "ports=[rnr1] rnr1=921 "

# the shipped conf: nothing configured (the service in the default runlevel is a no-op)
r=$(
	eerror() { :; }; LAN_CONF_FILE="$SRC/conf.d/gt-be98-lan"
	. "$SRC/init.d/gt-be98-lan"
	wifi_trunk() { echo rnr0; }
	load_conf && echo "ok [$LAN_PORTS] [$VPORTS] [$LAN_ADDR]"
)
[ "$r" = "ok [] [] []" ] && ok "the shipped conf.d: loads, no LAN port, no VLAN jack, no address (start is the no-op)" || ko "the shipped conf.d: [$r]"

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
if [ $NFT_OK != 2 ]; then
	nft_check "$T/g1.nft" && ok "BPDU guard (1 jack): nft -c accepts it" || { ko "BPDU guard (1 jack): nft -c"; cat "$T/nft.err"; }
	nft_check "$T/g2.nft" && ok "BPDU guard (2 jacks, 1 latched): nft -c accepts it" || { ko "BPDU guard (2 jacks): nft -c"; cat "$T/nft.err"; }
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
: > "$T/svc/seq"; svcf stop
[ ! -s "$T/svc/seq" ] && ok "empty conf: stop runs no command" || ko "empty conf stop: [$(tr '\n' '|' < "$T/svc/seq")]"
printf 'WIFI_TRUNK="rnr0"\nWIFI_VLANS="brwifi7:921 brwifi8:30"\n' > "$T/svc/l2.conf"
printf 'LAN_PORT_rnr1="native=921 tagged=none"\nLAN_PORT_rnr3="native=55"\n' > "$T/lan.conf"
: > "$T/svc/seq"; svcf start; r=$?
o=$(grep -v '^ip link set rnr[13] up$\|^ip -4 addr flush' "$T/svc/seq" | tr '\n' '|')
case "$o" in
"E LAN_PORT_rnr3: no network on VLAN 55"*"|nft -c -f -|nft -f -|l2 up lan brwifi7 rnr0 921|ip link set rnr1 master brwifi7|modprobe rtl8372|")
	ok "start: a jack without a network refused, the guard before the jack joins, rnr1 into brwifi7 (VLAN 921), then the switch" ;;
*) ko "start sequence: [$o]" ;;
esac
[ $r = 0 ] && ok "start: rc 0 with a jack not bridged yet (a Wi-Fi reload retries)" || ko "start rc $r"
check_applied() { if [ "$(tr '\n' '|' < "$T/svc/applied")" = "$1" ]; then ok "applied: $1"; else ko "applied: want [$1] got [$(tr '\n' '|' < "$T/svc/applied")]"; fi; }
check_applied "guard|vport rnr1 brwifi7 921|module rtl8372|"
# the network of 921 becomes brwifi8's (the list changed): reload moves the jack
printf 'WIFI_TRUNK="rnr0"\nWIFI_VLANS="brwifi8:921"\n' > "$T/svc/l2.conf"
: > "$T/svc/seq"; svcf reload
o=$(grep -v '^ip link set rnr[13] \(up\|down\)$\|^ip -4 addr flush\|^E ' "$T/svc/seq" | tr '\n' '|')
[ "$o" = "ip link set rnr1 nomaster|l2 down lan brwifi7|nft -c -f -|nft -f -|l2 up lan brwifi8 rnr0 921|ip link set rnr1 master brwifi8|" ] &&
	ok "reload: the jack leaves brwifi7, which is let go, and joins brwifi8; no module reload" || ko "reload: [$o]"
: > "$T/svc/seq"; svcf reload
o=$(grep -v '^ip link set rnr[13] up$\|^E ' "$T/svc/seq" | tr '\n' '|')
[ "$o" = "nft -c -f -|nft -f -|l2 up lan brwifi8 rnr0 921|" ] && ok "reload with nothing changed: no move (the user re-asserted)" || ko "reload unchanged: [$o]"
echo rnr1 > "$T/svc/tripped"
: > "$T/svc/seq"; svcf reload
grep -q '^bridge link set dev rnr1 state 0$' "$T/svc/seq" && ok "reload: a latched jack stays disabled" || ko "reload latched: [$(tr '\n' '|' < "$T/svc/seq")]"
: > "$T/svc/seq"; svcf stop
o=$(grep -v '^ip link set rnr1 down$' "$T/svc/seq" | tr '\n' '|')
[ "$o" = "nft delete table bridge gt_be98_lan_guard|ip link set rnr1 nomaster|rmmod rtl8372|l2 down lan brwifi8|" ] &&
	ok "stop: guard table deleted, the jack out, its network bridge let go once" || ko "stop: [$o]"
[ ! -e "$T/svc/applied" ] && [ ! -e "$T/svc/tripped" ] && ok "stop: applied state and the latch cleared" || ko "stop: state left"

echo "gt-be98-lan-test: $pass ok, $fail failed"
[ $fail -eq 0 ]

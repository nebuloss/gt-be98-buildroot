#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# hwsim test of the MESH BACKHAUL's OS plumbing (buildroot docs/MESH-BACKHAUL-DESIGN.md §5.3): the
# generator's backhaul= BSS and station trunk=1, gt-be98-mesh (the hostapd_cli -a hook), gt-be98-l2's
# downlink (bh<k>.<vid>) and uplink (bhs.<vid>) trunks, gt-be98-netguard's rule 7 and the leaf's loop guard,
# end to end over a real 4-address Multi-AP link. On a Linux BUILD host with mac80211_hwsim, as root; touches
# no real radio and no host network: everything runs in network namespaces (mroot, mleaf, mrogue and one per
# client), the hwsim radios are virtual. hwsim is own-MLME (mac80211): this checks the OS, never our driver.
#   sudo sh test/mesh-hwsim-test.sh HOSTAPD_SRC WPAS_SRC WORKDIR
# HOSTAPD_SRC / WPAS_SRC: the OS's hostapd-2.12 and wpa_supplicant-2.12 trees (<buildroot output>/build/...),
# copied to WORKDIR (scratch, removed first, delete it afterwards) and built host-native (libnl-3/libnl-genl-3
# and OpenSSL headers on the host). WORKDIR: an absolute path whose last component contains "hwsim".
# Topology: ROOT netns mroot (hwsim radio 0 renamed bcawl3, the generator's 2.4 GHz backhaul BSS, a dummy
# rnr0 as the wired trunk; networks 10 (VLAN) and 20 (gateway, bhvid=220) with a "gateway" netns each:
# g10 10.10.0.1, g20 10.20.0.1), LEAF netns mleaf (radio 1 renamed bcawl1, the generator's station trunk=1,
# bridges on bhs.10 / bhs.220; clients c10 10.10.0.2 in VLAN 10 and c20 in VLAN 220 with the address
# 10.10.0.3: VLAN 10's subnet, so only L2 separation keeps it from g10), ROGUE netns mrogue (radio 2, a
# Multi-AP backhaul STA with the key whose MAC is not a leaf=).
# Cells (each with its control):
#   T1 the leaf joins (COMPLETED, 4addr) and the root's hook makes the trunk: bh0.10 in brwifi10, bh0.220 in
#      brwifi20 (the gateway network on its bhvid), the AP_VLAN no bridge port; status lists the link
#   T2 data: c10 pings g10 (3/3) and c20 pings g20; control: c20 (VLAN 220, address of VLAN 10's subnet)
#      cannot reach g10 (0/3); the frames on the AP_VLAN carry 802.1Q tags 10 and 220 (tcpdump -e)
#   T3 the rogue STA (not the leaf=) is refused at association (the backhaul BSS's macaddr_acl=1 + accept
#      file, one leaf per backhaul BSS: design §8.2): never COMPLETED, no AP_VLAN, no bh1
#   T4 netguard rule 7 at the root: the AP_VLAN enslaved by hand into brwifi10 is detached, bh0.10 kept
#   T5 the leaf's loop guard: no latch without a loop (control), then a veth "rnr2" from the leaf's brwifi10
#      to the root's brwifi10 closes a loop through the backhaul: the guard's probe comes back on rnr2, rnr2
#      is latched and detached
#   T6 the leaf leaves: WDS-STA-INTERFACE-REMOVED frees the trunk (no bh0.*, gt-be98-l2 trunks empty)
# Exit 0 only when every cell is as expected.
set -u
hsrc=${1:?HOSTAPD_SRC}; wsrc=${2:?WPAS_SRC}; w=${3:?WORKDIR}
here=$(cd "$(dirname "$0")" && pwd)
S=$here/../src/sbin
[ "$(id -u)" = 0 ] || { echo "needs root (modprobe mac80211_hwsim, netns)"; exit 2; }
[ -f "$hsrc/hostapd/main.c" ] && [ -f "$wsrc/wpa_supplicant/main.c" ] || { echo "no hostapd/wpa_supplicant tree at $hsrc / $wsrc"; exit 2; }
modinfo mac80211_hwsim > /dev/null 2>&1 || /sbin/modinfo mac80211_hwsim > /dev/null 2>&1 || { echo "no mac80211_hwsim"; exit 2; }
PATH=$PATH:/sbin:/usr/sbin
for c in iw nft arping tcpdump bridge; do command -v $c > /dev/null || { echo "no $c on this host"; exit 2; }; done
case "$w" in /*/*hwsim*) ;; *) echo "refusing WORKDIR '$w': an absolute scratch path whose last component contains 'hwsim'"; exit 2 ;; esac
case "${w##*/}" in *hwsim*) ;; *) echo "refusing WORKDIR '$w': the last component must contain 'hwsim'"; exit 2 ;; esac
lsmod | grep -q '^mac80211_hwsim ' && { echo "mac80211_hwsim is loaded already (another test?): refusing"; exit 2; }
NS="mroot mleaf mrogue g10 g20 c10 c20"
for n in $NS; do ip netns list | grep -qw "$n" && { echo "netns $n exists already: refusing"; exit 2; }; done
rm -rf "$w"; mkdir -p "$w/lib" "$w/root/run/gt-be98-wifi/gen" "$w/leaf/run/gt-be98-wifi/gen" "$w/rogue"
[ -e /usr/lib/x86_64-linux-gnu/libnl-genl-3.so ] || ln -sf /usr/lib/x86_64-linux-gnu/libnl-genl-3.so.200 "$w/lib/libnl-genl-3.so"
cleanup() {
	for p in $(cat "$w"/*.pid "$w"/*/*.pid "$w"/*/run/*.pid 2>/dev/null); do kill "$p" 2>/dev/null; done
	sleep 1
	for n in $NS; do ip netns del "$n" 2>/dev/null; done
	modprobe -r mac80211_hwsim 2>/dev/null
}
trap cleanup EXIT
CFLAGS_="-g -O1 -I/usr/include/libnl3 -MMD"
build() {	# build SRC NAME TARGETS...
	local s=$1 n=$2; shift 2
	cp -a "$s" "$w/$n"
	(cd "$w/$n" && find . \( -name '*.o' -o -name '*.d' \) -exec rm -f {} + && rm -rf build)
	(cd "$w/$n/${n%-*}" &&
		printf '%s\n' CONFIG_DRIVER_NL80211=y CONFIG_LIBNL32=y CONFIG_IEEE80211N=y CONFIG_IEEE80211AC=y \
			CONFIG_IEEE80211AX=y CONFIG_IEEE80211BE=y CONFIG_SAE=y CONFIG_CTRL_IFACE=y CONFIG_DEBUG_FILE=y \
			CONFIG_NO_RANDOM_POOL=y CONFIG_OWE=y > .config &&
		CFLAGS="$CFLAGS_" LDFLAGS="-L$w/lib" make -s -j"$(nproc)" "$@" > ../make.log 2>&1) ||
		{ tail -5 "$w/$n/make.log"; return 1; }
}
build "$hsrc" hostapd-b hostapd hostapd_cli || { echo "hostapd build failed"; exit 1; }
build "$wsrc" wpa_supplicant-b wpa_supplicant wpa_cli || { echo "wpa_supplicant build failed"; exit 1; }
HAPD=$w/hostapd-b/hostapd/hostapd HCLI=$w/hostapd-b/hostapd/hostapd_cli
WPAS=$w/wpa_supplicant-b/wpa_supplicant/wpa_supplicant WCLI=$w/wpa_supplicant-b/wpa_supplicant/wpa_cli
# hostapd_cli as the OS calls it (gt-be98-mesh's deauthenticate): this build first in PATH
mkdir -p "$w/bin"; ln -sf "$HCLI" "$w/bin/hostapd_cli"; PATH=$w/bin:$PATH
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want [$2] got [$3]"; fail=1; fi; }
until_() {	# until_ SECONDS COMMAND...: poll every 0.5 s, rc 0 when it held
	local n=$(( $1 * 2 )); shift
	while [ $n -gt 0 ]; do "$@" > /dev/null 2>&1 && return 0; sleep 0.5; n=$((n - 1)); done
	return 1
}
modprobe mac80211_hwsim radios=3 || { echo "modprobe failed"; exit 1; }
sleep 1
for n in $NS; do ip netns add "$n"; ip netns exec "$n" sh -c 'sysctl -qw net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1; ip link set lo up'; done
phys=$(for p in /sys/class/ieee80211/*; do [ -d "$p/device/net" ] && ls "$p/device/net" | grep -q '^wlan' && basename "$p"; done | head -3)
set -- $phys
[ $# = 3 ] || { echo "hwsim: 3 phys expected, got '$phys'"; exit 1; }
mv_phy() {	# mv_phy PHY NETNS NAME: the phy's netdev into NETNS as NAME
	local d
	d=$(ls "/sys/class/ieee80211/$1/device/net" | grep -m1 '^wlan')
	iw phy "$1" set netns name "$2" &&
		ip netns exec "$2" ip link set "$d" name "$3"
}
mv_phy "$1" mroot bcawl3 && mv_phy "$2" mleaf bcawl1 && mv_phy "$3" mrogue wlan9 || { echo "phy move failed"; exit 1; }
R() { ip netns exec mroot env GT_BE98_RUN="$w/root/run" GT_BE98_NETWORKS="$w/root/networks.conf" GT_BE98_CONFD=/nonexistent \
	GT_BE98_CONFAP=/nonexistent GT_BE98_L2="$S/gt-be98-l2" GT_BE98_WIFI_GEN="$S/gt-be98-wifi-gen" "$@"; }
F() { ip netns exec mleaf env GT_BE98_RUN="$w/leaf/run" GT_BE98_NETWORKS="$w/leaf/networks.conf" GT_BE98_CONFD=/nonexistent \
	GT_BE98_CONFAP=/nonexistent GT_BE98_L2="$S/gt-be98-l2" GT_BE98_WIFI_GEN="$S/gt-be98-wifi-gen" "$@"; }
RMAC=$(ip netns exec mroot cat /sys/class/net/bcawl3/address)
LMAC=$(ip netns exec mleaf cat /sys/class/net/bcawl1/address)
# ---- the root: the generator's backhaul BSS, the network bridges ----
printf 'radio=2g\nchannel=6\nbackhaul=2g\nssid=mesh-bh\npassphrase=hwsim-mesh-1\nleaf=%s\n' "$LMAC" > "$w/root/list"
R sh "$S/gt-be98-wifi-gen" -n "$w/root/list" -o "$w/root/run/gt-be98-wifi/gen" -d "2g=bcawl3 5gl=bcawl90 5gh=bcawl91 6g=bcawl92" -m "2g=$RMAC" \
	-x "$w/root/run/hostapd" 2> "$w/root/gen.err" || { cat "$w/root/gen.err"; echo "root list refused"; exit 1; }
check "generator: the backhaul line of the root, its one leaf" "backhaul 2g bcawl3 bcawl3 $RMAC|$LMAC" "$(grep '^backhaul ' "$w/root/run/gt-be98-wifi/gen/plan")|$(cat "$w/root/run/gt-be98-wifi/gen/accept-bcawl3")"
printf 'network=10 name=Ten vlan=10\nnetwork=20 name=Twenty vlan=20 subnet=10.20.0.1/24 mode=gateway bhvid=220\n' > "$w/root/networks.conf"
ip netns exec mroot ip link add rnr0 type dummy
R sh "$S/gt-be98-l2" up wifi brwifi10 rnr0 10 && R sh "$S/gt-be98-l2" up wifi brwifi20 rnr0 20 || { echo "root bridges failed"; exit 1; }
veth() {	# veth NS_BR BRIDGE PORT NS_PEER ADDR: a veth PORT in BRIDGE of NS_BR, its peer eth0 in NS_PEER with ADDR
	ip netns exec "$1" ip link add "$3" type veth peer name "$3p" &&
	ip netns exec "$1" ip link set "$3p" netns "$4" &&
	ip netns exec "$1" ip link set "$3" master "$2" up &&
	ip netns exec "$4" ip link set "$3p" name eth0 &&
	ip netns exec "$4" ip addr add "$5" dev eth0 && ip netns exec "$4" ip link set eth0 up
}
veth mroot brwifi10 vg10 g10 10.10.0.1/24 && veth mroot brwifi20 vg20 g20 10.20.0.1/24 || { echo "root veths failed"; exit 1; }
R "$HAPD" -B -P "$w/root/hostapd.pid" -t -dd -f "$w/root/hostapd.log" "$w/root/run/gt-be98-wifi/gen/hostapd-bcawl3.conf" ||
	{ tail -20 "$w/root/hostapd.log"; echo "root hostapd failed"; exit 1; }
until_ 15 grep -q AP-ENABLED "$w/root/hostapd.log" || { tail -20 "$w/root/hostapd.log"; echo "backhaul BSS not ENABLED"; exit 1; }
R "$HCLI" -B -r -P "$w/root/hook.pid" -p "$w/root/run/hostapd" -i bcawl3 -a "$S/gt-be98-mesh" || { echo "hostapd_cli hook failed"; exit 1; }
# ---- the leaf: the generator's station trunk=1, the bridges on bhs ----
printf 'station=2g\nssid=mesh-bh\nsecurity=sae\npassphrase=hwsim-mesh-1\nrepeater=multiap\ntrunk=1\n' > "$w/leaf/list"
F sh "$S/gt-be98-wifi-gen" -n "$w/leaf/list" -o "$w/leaf/run/gt-be98-wifi/gen" -d "2g=bcawl1 5gl=bcawl90 5gh=bcawl91 6g=bcawl92" -m "2g=$LMAC" \
	-X "$w/leaf/run/wpa_supplicant" 2> "$w/leaf/gen.err" || { cat "$w/leaf/gen.err"; echo "leaf list refused"; exit 1; }
check "generator: the leaf's bhtrunk line (no Wi-Fi network in its list)" "bhtrunk bcawl1 -" "$(grep '^bhtrunk ' "$w/leaf/run/gt-be98-wifi/gen/plan")"
printf 'network=10 vlan=10\nnetwork=20 vlan=220\n' > "$w/leaf/networks.conf"
F sh "$S/gt-be98-l2" uplink bcawl1 && F sh "$S/gt-be98-l2" up wifi brwifi10 bhs 10 && F sh "$S/gt-be98-l2" up wifi brwifi20 bhs 220 ||
	{ echo "leaf bridges failed"; exit 1; }
veth mleaf brwifi10 vc10 c10 10.10.0.2/24 && veth mleaf brwifi20 vc20 c20 10.10.0.3/24 || { echo "leaf veths failed"; exit 1; }
# gt-be98-wifi-sta's order: 4-address mode before the join, the station no bridge port
ip netns exec mleaf iw dev bcawl1 set 4addr on && ip netns exec mleaf ip link set bcawl1 up
ip netns exec mleaf "$WPAS" -B -i bcawl1 -c "$w/leaf/run/gt-be98-wifi/gen/sta-bcawl1.conf" -P "$w/leaf/wpas.pid" -t -dd -f "$w/leaf/wpas.log"
wst() { ip netns exec mleaf "$WCLI" -p "$w/leaf/run/wpa_supplicant" -i bcawl1 status 2>/dev/null | sed -n 's/^wpa_state=//p'; }
until_ 30 sh -c "[ \"\$(ip netns exec mleaf $WCLI -p $w/leaf/run/wpa_supplicant -i bcawl1 status 2>/dev/null | sed -n 's/^wpa_state=//p')\" = COMPLETED ]"
check "T1 leaf: COMPLETED, 4addr on" "COMPLETED 4addr: on" "$(wst) $(ip netns exec mleaf iw dev bcawl1 info | grep -o '4addr: on')"
until_ 10 ip netns exec mroot test -e /sys/class/net/bh0.10
mst() { ip netns exec "$1" sh -c "m=\$(readlink /sys/class/net/$2/master 2>/dev/null); echo \${m##*/}"; }
AV=$(ip netns exec mroot ls /sys/class/net | grep -m1 '^bcawl3\.sta')
check "T1 root: the AP_VLAN made by hostapd" "yes" "$([ -n "$AV" ] && echo yes || echo no)"
check "T1 root: bh0.10 in brwifi10, bh0.220 in brwifi20 (gateway network on its bhvid), AP_VLAN no port" "brwifi10 brwifi20 -" \
	"$(mst mroot bh0.10) $(mst mroot bh0.220) $(mst mroot "$AV")-"
check "T1 root: gt-be98-mesh status lists the link" "link bh0 $AV $LMAC vids=10,220" "$(R sh "$S/gt-be98-mesh" status | grep '^link')"
check "T1 leaf: bhs.10 in brwifi10, bhs.220 in brwifi20, the station no port" "brwifi10 brwifi20 -" \
	"$(mst mleaf bhs.10) $(mst mleaf bhs.220) $(mst mleaf bcawl1)-"
# ---- T2 data, VLAN separation, tags on the air link ----
ip netns exec mroot tcpdump -i "$AV" -e -nn -c 40 -w "$w/root/av.pcap" > /dev/null 2>&1 & echo $! > "$w/tcpdump.pid"
sleep 1
pg() { ip netns exec "$1" ping -c 3 -i 0.3 -W 1 -q "$2" 2>/dev/null | sed -n 's/.* \([0-9]*\) received.*/\1/p'; }
check "T2 c10 -> g10 (VLAN 10 across the backhaul)" 3 "$(pg c10 10.10.0.1)"
ip netns exec c20 ip addr add 10.20.0.2/24 dev eth0
check "T2 c20 -> g20 (gateway network, backhaul VID 220)" 3 "$(pg c20 10.20.0.1)"
check "T2 control: c20 (VLAN 220, an address of VLAN 10's subnet) never reaches g10" 0 "$(pg c20 10.10.0.1)"
sleep 1; kill "$(cat "$w/tcpdump.pid")" 2>/dev/null; sleep 1
tags=$(tcpdump -r "$w/root/av.pcap" -e -nn 2>/dev/null | grep -o 'vlan [0-9]*' | sort -u | tr '\n' ' ')
check "T2 the AP_VLAN carries 802.1Q tags 10 and 220" "vlan 10 vlan 220 " "$tags"
# ---- T3 a backhaul STA that is not a leaf= ----
printf 'ctrl_interface=%s/rogue/ctl\nnetwork={\n ssid="mesh-bh"\n key_mgmt=SAE\n ieee80211w=2\n sae_pwe=2\n sae_password="hwsim-mesh-1"\n multi_ap_backhaul_sta=1\n scan_ssid=1\n}\n' "$w" > "$w/rogue/sta.conf"
ip netns exec mrogue iw dev wlan9 set 4addr on; ip netns exec mrogue ip link set wlan9 up
ip netns exec mrogue "$WPAS" -B -i wlan9 -c "$w/rogue/sta.conf" -P "$w/rogue/wpas.pid" -t -f "$w/rogue/wpas.log"
sleep 20
GMAC=$(ip netns exec mrogue cat /sys/class/net/wlan9/address)
check "T3 rogue (not the leaf): never COMPLETED (macaddr_acl=1, one leaf per backhaul BSS), no second AP_VLAN, no bh1" "no 1 no" \
	"$(ip netns exec mrogue "$WCLI" -p "$w/rogue/ctl" -i wlan9 status 2>/dev/null | grep -q '^wpa_state=COMPLETED' && echo yes || echo no) $(ip netns exec mroot ls /sys/class/net | grep -c '^bcawl3\.sta') $(ip netns exec mroot test -e /sys/class/net/bh1.10 && echo yes || echo no)"
check "T3 control: the leaf's trunk is still the only one" "1" "$(R sh "$S/gt-be98-l2" trunks | grep -c '^bh')"
kill "$(cat "$w/rogue/wpas.pid")" 2>/dev/null
# ---- T4 netguard rule 7 at the root ----
printf 'WIFI_TRUNK="rnr0"\nWIFI_VLANS="brwifi10:10 brwifi20:20"\nWIFI_ISOLATE=""\n' > "$w/root/l2.conf"
NGR() { R env GT_BE98_WIFI_L2="$w/root/l2.conf" GT_BE98_WIFI_STATIONS="$w/root/stations" GT_BE98_WIFI_REPEATERS="$w/root/repeaters" \
	GT_BE98_LAN_CONF=/nonexistent GT_BE98_WIFI_PLAN="$w/root/run/gt-be98-wifi/gen/plan" GT_BE98_RTL8372=/nonexistent sh "$S/gt-be98-netguard" --sweep; }
ip netns exec mroot ip link set "$AV" master brwifi10
NGR
check "T4 netguard: the AP_VLAN put into brwifi10 is detached, bh0.10 and rnr0.10 kept" "- brwifi10 brwifi10" "$(mst mroot "$AV")- $(mst mroot bh0.10) $(mst mroot rnr0.10)"
check "T4 control: the link still passes data after the sweep" 3 "$(pg c10 10.10.0.1)"
# ---- T5 the leaf's loop guard ----
printf 'WIFI_TRUNK="bhs"\nWIFI_VLANS="brwifi10:10 brwifi20:220"\nWIFI_ISOLATE=""\n' > "$w/leaf/l2.conf"
echo bcawl1 > "$w/leaf/stations"; printf 'LAN_PORT_rnr2="native=10"\n' > "$w/leaf/lan.conf"
NGL() { F env GT_BE98_WIFI_L2="$w/leaf/l2.conf" GT_BE98_WIFI_STATIONS="$w/leaf/stations" GT_BE98_WIFI_REPEATERS="$w/leaf/repeaters" \
	GT_BE98_LAN_CONF="$w/leaf/lan.conf" GT_BE98_WIFI_PLAN="$w/leaf/run/gt-be98-wifi/gen/plan" GT_BE98_RTL8372=/nonexistent \
	BH_PROBE_EVERY=1 sh "$S/gt-be98-netguard" --sweep; }
NGL; NGL
check "T5 control: no loop: the guard is loaded, nothing latched" "yes -" \
	"$(ip netns exec mleaf nft list table bridge gt_be98_bh_guard > /dev/null 2>&1 && echo yes || echo no) $(cat "$w/leaf/run/gt-be98-lan.tripped" 2>/dev/null)-"
# the loop: a leaf jack rnr2 (native VLAN 10) cabled to the root's VLAN 10
ip netns exec mleaf ip link add rnr2 type veth peer name lp2 && ip netns exec mleaf ip link set lp2 netns mroot &&
	ip netns exec mroot ip link set lp2 master brwifi10 up && ip netns exec mleaf ip link set rnr2 master brwifi10 up
NGL
check "T5 netguard keeps the VLAN jack rnr2 in its native network's leaf bridge" brwifi10 "$(mst mleaf rnr2)"
n=0; while [ $n -lt 6 ] && ! grep -qx rnr2 "$w/leaf/run/gt-be98-lan.tripped" 2>/dev/null; do NGL; n=$((n + 1)); done
NGL
check "T5 the loop: the station's own probe came back on rnr2: latched and detached" "rnr2 -" \
	"$(grep -x rnr2 "$w/leaf/run/gt-be98-lan.tripped" 2>/dev/null) $(mst mleaf rnr2)-"
check "T5 control: the backhaul VLANs stay" "brwifi10 brwifi20" "$(mst mleaf bhs.10) $(mst mleaf bhs.220)"
# ---- T6 the leaf leaves ----
kill "$(cat "$w/leaf/wpas.pid")" 2>/dev/null
until_ 15 sh -c "! ip netns exec mroot test -e /sys/class/net/bh0.10"
check "T6 leaf gone: no bh0.10/bh0.220, no trunk" "no no 0" \
	"$(ip netns exec mroot test -e /sys/class/net/bh0.10 && echo yes || echo no) $(ip netns exec mroot test -e /sys/class/net/bh0.220 && echo yes || echo no) $(R sh "$S/gt-be98-l2" trunks | grep -c '^bh')"
if [ $fail = 0 ]; then echo "ALL OK (mesh hwsim)"; else echo "FAILED (logs in $w)"; trap - EXIT; cleanup; fi
exit $fail

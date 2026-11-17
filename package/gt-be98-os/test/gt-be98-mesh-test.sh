#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# Offline test of sbin/gt-be98-mesh (the mesh backhaul's hostapd hook, sync,
# status, export/import) with the real gt-be98-l2 and gt-be98-wifi-gen (no
# device, no root): sh test/gt-be98-mesh-test.sh
# A fake `ip` keeps a fake sysfs and 802.1Q table (as gt-be98-l2-test.sh), a
# fake hostapd_cli records the deauthentications, a fake iw answers the
# AP_VLANs' station dump. Every check has a control that differs in one input.
set -u
here=$(cd "$(dirname "$0")" && pwd)
MESH="$here/../src/sbin/gt-be98-mesh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
N=$T/net
export GT_BE98_RUN="$T/run" GT_BE98_SYSNET="$N" GT_BE98_VLANCFG="$T/vlancfg" GT_BE98_PROCNET="$T/procnet" FAKE="$T"
export GT_BE98_L2="$here/../src/sbin/gt-be98-l2" GT_BE98_WIFI_GEN="$here/../src/sbin/gt-be98-wifi-gen"
export GT_BE98_NETWORKS="$T/networks.conf" GT_BE98_CONFD="$T/confd" GT_BE98_CONFAP="$T/confap"
mkdir -p "$T/bin" "$T/run/gt-be98-wifi/gen" "$N"
: > "$T/vlancfg"
cat > "$T/bin/ip" <<'X'
#!/bin/sh
N=$GT_BE98_SYSNET
echo "ip $*" >> "$FAKE/iplog"
[ "$1" = link ] || exit 0
shift
case "$*" in
"add name "*" type bridge "*)	b=$3; [ -e "$N/$b" ] && exit 2; mkdir -p "$N/$b/bridge" "$N/$b/brif"; echo 0 > "$N/$b/flags" ;;
"add link "*" name "*" type vlan id "*)	s=$5; [ -e "$N/$s" ] && exit 2; mkdir -p "$N/$s"; echo 0 > "$N/$s/flags"; echo "$s | $9 | $3" >> "$FAKE/vlancfg" ;;
"set dev "*" master "*)	x=$3; b=$5; [ -d "$N/$b/brif" ] || exit 1
	m=$(readlink "$N/$x/master"); [ -n "$m" ] && rm -f "$N/${m##*/}/brif/$x"
	ln -sfn "../$b" "$N/$x/master"; ln -sfn "../../$x" "$N/$b/brif/$x" ;;
"set dev "*" nomaster")	x=$3; m=$(readlink "$N/$x/master"); rm -f "$N/$x/master"; [ -n "$m" ] && rm -f "$N/${m##*/}/brif/$x" ;;
"set dev "*" up")	echo 1 > "$N/$3/flags" ;;
"set dev "*" type bridge "*) ;;
"del dev "*)	x=$3; [ -e "$N/$x" ] || exit 1
	m=$(readlink "$N/$x/master"); [ -n "$m" ] && rm -f "$N/${m##*/}/brif/$x"
	for p in "$N/$x/brif"/*; do [ -L "$p" ] && rm -f "$N/${p##*/}/master"; done
	rm -rf "${N:?}/$x"; grep -v "^$x |" "$FAKE/vlancfg" > "$FAKE/v.new"; mv "$FAKE/v.new" "$FAKE/vlancfg" ;;
*) echo "fake ip: unhandled: link $*" >&2; exit 1 ;;
esac
exit 0
X
printf '#!/bin/sh\necho "bridge $*" >> "$FAKE/iplog"\n' > "$T/bin/bridge"
printf '#!/bin/sh\necho "$*" >> "$FAKE/log"\n' > "$T/bin/logger"
printf '#!/bin/sh\necho "hostapd_cli $*" >> "$FAKE/hcli"\n' > "$T/bin/hostapd_cli"
# iw dev <apvlan> station dump: the peer in $FAKE/peer-<apvlan>
printf '#!/bin/sh\n[ "$1 $3 $4" = "dev station dump" ] && [ -f "$FAKE/peer-$2" ] && echo "Station $(cat "$FAKE/peer-$2") (on $2)"\nexit 0\n' > "$T/bin/iw"
chmod +x "$T/bin/"*
PATH="$T/bin:$PATH"
port() { mkdir -p "$N/$1"; echo "${2:-1}" > "$N/$1/flags"; }
master() { m=$(readlink "$N/$1/master" 2>/dev/null); echo "${m##*/}"; }
ex() { [ -e "$N/$1" ] && echo yes || echo no; }
pass=0 fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   $1"; else fail=$((fail + 1)); echo "FAIL $1: want [$2] got [$3]"; fi; }
H() { sh "$MESH" "$@" 2>> "$T/err"; }
L2() { sh "$GT_BE98_L2" "$@" 2>> "$T/err"; }
PLAN=$T/run/gt-be98-wifi/gen/plan

# ---- the root: plan with a backhaul line, two network bridges ----
port rnr0
printf 'network=4 name=Lab vlan=44 subnet=192.168.40.1/24 mode=gateway bhvid=444\nnetwork=3 name=Up vlan=30\nnetwork=5 name=Gw vlan=55 subnet=192.168.55.1/24 mode=gateway\n' > "$GT_BE98_NETWORKS"
L2 up wifi brwifi4 rnr0 44; L2 up wifi brwifi3 rnr0 30
printf 'backhaul 5gl bcawl0 bcawl0-1 aa:00:00:00:00:19\n' > "$PLAN"
echo 02:00:00:00:00:0A > "${PLAN%/plan}/accept-bcawl0-1"	# the generator's accept file: the one leaf
port bcawl0-1.sta1
H bcawl0-1 WDS-STA-INTERFACE-ADDED ifname=bcawl0-1.sta1 sta_addr=02:00:00:00:00:0A
check "hook ADDED, a listed leaf (upper case): rc 0, bh0.30 in brwifi3, bh0.444 in brwifi4" "0 brwifi3 brwifi4" "$? $(master bh0.30) $(master bh0.444)"
check "... MESH-LINK-UP logged with the VIDs" yes "$(grep -q 'MESH-LINK-UP bh0 dev=bcawl0-1.sta1 peer=02:00:00:00:00:0a vids=30,444' "$T/log" && echo yes || echo no)"
check "... the untagged AP_VLAN is no bridge port, nobody deauthenticated" "- 0" "$(master bcawl0-1.sta1)- $(grep -c deauth "$T/hcli" 2>/dev/null || echo 0)"
port bcawl0-1.sta2
H bcawl0-1 WDS-STA-INTERFACE-ADDED ifname=bcawl0-1.sta2 sta_addr=02:00:00:00:00:99
check "hook ADDED, a peer not in leaf=: no trunk, deauthenticated on the backhaul BSS" "no hostapd_cli -p $T/run/hostapd -i bcawl0-1 deauthenticate 02:00:00:00:00:99" \
	"$(ex bh1.30) $(cat "$T/hcli")"
check "... MESH-LINK-REFUSED logged, status lists it" "yes refused 02:00:00:00:00:99" "$(grep -q 'MESH-LINK-REFUSED peer=02:00:00:00:00:99' "$T/log" && echo yes || echo no) $(H status | grep '^refused')"
H bcawl0-1 AP-STA-CONNECTED 02:00:00:00:00:0b
check "another event: ignored (nothing made)" "0 no" "$? $(ex bh1.30)"
H bcawl0-1 WDS-STA-INTERFACE-ADDED ifname=bcawl3.sta1 sta_addr=02:00:00:00:00:0b
check "an ifname that is not an AP_VLAN of the ctrl ifname: ignored" "no" "$(ex bh1.30)"
H bcawl0-1 WDS-STA-INTERFACE-ADDED ifname=bcawl0-1.sta2 sta_addr=nonsense
check "a bad sta_addr: ignored" "no" "$(ex bh1.30)"
check "status (root): role, backhaul, the link" "role root|backhaul 5gl bcawl0-1 aa:00:00:00:00:19 leaves=02:00:00:00:00:0a|link bh0 bcawl0-1.sta1 02:00:00:00:00:0a vids=30,444|refused 02:00:00:00:00:99" \
	"$(H status | tr '\n' '|' | sed 's/|$//')"
# no accept file (a hand-made BSS): no leaf known, nobody gets a trunk
rm -f "${PLAN%/plan}/accept-bcawl0-1"
H bcawl0-1 WDS-STA-INTERFACE-ADDED ifname=bcawl0-1.sta2 sta_addr=02:00:00:00:00:0a
check "no accept file: even the former leaf gets no trunk" "no" "$(ex bh1.30)"
# control: the second station IS the leaf now: bh1
echo 02:00:00:00:00:99 > "${PLAN%/plan}/accept-bcawl0-1"
H bcawl0-1 WDS-STA-INTERFACE-ADDED ifname=bcawl0-1.sta2 sta_addr=02:00:00:00:00:99
check "control: the peer that is the leaf gets bh1, no longer refused" "brwifi3 no" "$(master bh1.30) $(H status | grep -q '^refused 02:00:00:00:00:99' && echo yes || echo no)"
H bcawl0-1 WDS-STA-INTERFACE-REMOVED ifname=bcawl0-1.sta2 sta_addr=02:00:00:00:00:99; rm -rf "$N/bcawl0-1.sta2"
check "hook REMOVED: bh1's VLANs deleted, bh0's kept, MESH-LINK-DOWN logged" "no brwifi3 yes" "$(ex bh1.30) $(master bh0.30) $(grep -q 'MESH-LINK-DOWN bh1 dev=bcawl0-1.sta2' "$T/log" && echo yes || echo no)"
# sync: a link made while hostapd_cli was not attached, one gone
rm -rf "$N/bcawl0-1.sta1" "$N/bh0.30" "$N/bh0.444"	# hostapd restarted: the AP_VLAN and its VLANs vanished
port bcawl0-1.sta3; echo 02:00:00:00:00:0b > "$T/peer-bcawl0-1.sta3"; echo 02:00:00:00:00:0b > "${PLAN%/plan}/accept-bcawl0-1"
H sync; check "sync: the gone link's trunk freed, the new AP_VLAN a trunk (peer from its station dump)" "0 bh0 bcawl0-1.sta3 02:00:00:00:00:0b brwifi3" \
	"$? $(L2 trunks | awk '{ print $1, $2, $4 }') $(master bh0.30)"
rm -f "$T/peer-bcawl0-1.sta3"; port bcawl0-1.sta4
H sync; check "sync: an AP_VLAN whose peer is unread gets no trunk" "no" "$(L2 trunks | grep -q 'bcawl0-1.sta4' && echo yes || echo no)"
# ---- export (root) -> import (leaf) ----
cat > "$T/rootlist" <<'X'
country=DE
radio=5gl
channel=36
network=3
ssid=Up net
security=psk2sae
passphrase=password3
bands=2g 5gl
vlan=30
bssid.5gl=02:00:00:00:01:01
network=4
ssid=Lab
security=sae
passphrase=password4
bands=5gl 6g
vlan=44
kv=1
network=9
ssid=Routed
security=sae
passphrase=password9
bands=2g
routed=192.168.90.1/24
station=2g
ssid=wan
security=psk2
passphrase=uplinkpw1
backhaul=5gl
ssid=mesh-bh
passphrase=SECRETbh12
X
H export -n "$T/rootlist" -o "$T/leaf.mesh"; check "export: rc 0, file mode 600" "0 600" "$? $(stat -c %a "$T/leaf.mesh")"
check "export: header, sections" "# gt-be98-mesh leaf v1|[wifi]|[networks]" "$(grep -E '^(# gt-be98|\[)' "$T/leaf.mesh" | tr '\n' '|' | sed 's/|$//')"
check "export: VLAN 30 as is, the gateway network 44 on its bhvid 444, routed 9 left out" "vlan=30|vlan=444|0" \
	"$(sed -n '/^\[wifi\]/,/^\[networks\]/p' "$T/leaf.mesh" | grep '^vlan=' | tr '\n' '|')$(grep -c 'Routed' "$T/leaf.mesh")"
check "export: the root's own bssid./station/radio not carried" "0 0 0" "$(grep -c '^bssid' "$T/leaf.mesh") $(grep -c '^ssid=wan' "$T/leaf.mesh") $(grep -c '^radio=' "$T/leaf.mesh")"
check "export: the leaf's station block (backhaul band, SAE, trunk)" "station=5gl|ssid=mesh-bh|security=sae|passphrase=SECRETbh12|repeater=multiap|trunk=1" \
	"$(sed -n '/^station=/,/^trunk=/p' "$T/leaf.mesh" | tr '\n' '|' | sed 's/|$//')"
check "export: the gateway network 5 without bhvid= does not cross (left out)" 0 "$(sed -n '/^\[networks\]/,$p' "$T/leaf.mesh" | grep -c '^network=5 ')"
check "export: the networks part (no gateway, no subnet, bhvid applied)" "network=4 name=Lab vlan=444|network=3 name=Up vlan=30" \
	"$(sed -n '/^\[networks\]/,$p' "$T/leaf.mesh" | grep '^network=' | tr '\n' '|' | sed 's/|$//')"
printf 'network=3\nssid=x\nsecurity=sae\npassphrase=password3\nbands=5gl\nvlan=30\n' > "$T/plain"
check "control: export of a list without backhaul=: refused" 1 "$(H export -n "$T/plain" > /dev/null; echo $?)"
# the leaf keeps its own country and radio blocks
printf 'country=FR\nradio=5gl\nchannel=40\nwidth=40\nnetwork=77\nssid=old\nsecurity=sae\npassphrase=password7\nbands=5gl\nvlan=77\n' > "$T/leaflist"
echo 'network=77 vlan=77' > "$T/leafnets"
H import "$T/leaf.mesh" -n "$T/leaflist" -g "$T/leafnets"; check "import: rc 0" 0 $?
check "import: the leaf's country and radio kept, its old network replaced, the export's networks and station" "country=FR|radio=5gl|channel=40|0|2|station=5gl|trunk=1" \
	"$(grep -E '^(country|radio|channel)=' "$T/leaflist" | tr '\n' '|')$(grep -c 'ssid=old' "$T/leaflist")|$(grep -c '^network=' "$T/leaflist")|$(grep -E '^(station|trunk)=' "$T/leaflist" | tr '\n' '|' | sed 's/|$//')"
check "import: the Wi-Fi list mode 600, the networks list written" "600 network=4 name=Lab vlan=444" "$(stat -c %a "$T/leaflist") $(grep '^network=4' "$T/leafnets")"
sh "$GT_BE98_WIFI_GEN" -n "$T/leaflist" -o "$T/lo" -m "2g=02:00:00:00:00:10 5gl=02:00:00:00:00:18 5gh=02:00:00:00:00:20 6g=02:00:00:00:00:28" 2> /dev/null
check "the imported list renders a leaf: bhtrunk on 5gl, net 4 on VLAN 444" "net 4 brwifi4 444 0|bhtrunk bcawl0 30,444" "$(grep -E '^(bhtrunk|net 4 )' "$T/lo/plan" | tr '\n' '|' | sed 's/|$//')"
cp "$T/leaflist" "$T/leaflist.keep"; cp "$T/leafnets" "$T/leafnets.keep"
# refusals: nothing written
sed 's/^# gt-be98-mesh leaf v1$/# something else/' "$T/leaf.mesh" > "$T/bad1"
check "import of another file: refused" 1 "$(H import "$T/bad1" -n "$T/leaflist" -g "$T/leafnets"; echo $?)"
sed 's/^passphrase=SECRETbh12$/passphrase=short/' "$T/leaf.mesh" > "$T/bad2"
check "import with a bad station passphrase (gt-be98-wifi-gen -Q refuses): refused" 1 "$(H import "$T/bad2" -n "$T/leaflist" -g "$T/leafnets"; echo $?)"
sed 's/^network=3 name=Up vlan=30$/network=3 name=Up vlan=30 mode=gateway subnet=10.0.0.1\/24/' "$T/leaf.mesh" > "$T/bad3"
check "import with a gateway line: refused (a leaf never routes)" 1 "$(H import "$T/bad3" -n "$T/leaflist" -g "$T/leafnets"; echo $?)"
grep -v '^trunk=1$' "$T/leaf.mesh" > "$T/bad4"
check "import without trunk=1: refused" 1 "$(H import "$T/bad4" -n "$T/leaflist" -g "$T/leafnets"; echo $?)"
check "... no refusal wrote anything" "" "$(cmp "$T/leaflist" "$T/leaflist.keep" 2>&1)$(cmp "$T/leafnets" "$T/leafnets.keep" 2>&1)"
check "... no secret in any message" no "$(grep -qE 'SECRETbh12|password3' "$T/err" "$T/log" && echo leak || echo no)"
# ---- the leaf's status ----
printf 'bhtrunk bcawl1\n' > "$PLAN"
port bcawl1; L2 uplink bcawl1; L2 up wifi brwifi5 bhs 50; L2 up wifi brwifi6 bhs 20
check "status (leaf): role leaf, uplink bhs with its VIDs" "role leaf|uplink bhs bcawl1 vids=20,50" "$(H status | tr '\n' '|' | sed 's/|$//')"
# the leaf's management address (D-MESH-OS1): dhcpcd's script, the status line
printf 'bhtrunk bcawl1 20,50\nbhmgmt 50 brwifi5\n' > "$PLAN"
check "status (leaf): mgmt line before a lease" "mgmt bhm0 brwifi5 50 -" "$(H status | grep '^mgmt')"
env reason=BOUND interface=bhm0 new_ip_address=10.50.0.7 new_subnet_cidr=24 new_routers=10.50.0.1 new_domain_name_servers=10.50.0.1 sh "$MESH" 2>> "$T/err"
check "dhcpcd BOUND on bhm0: lease recorded, default via its router at metric 2500" "mgmt bhm0 brwifi5 50 10.50.0.7/24|yes" \
	"$(H status | grep '^mgmt')|$(grep -q 'route replace default via 10.50.0.1 dev bhm0 metric 2500' "$T/iplog" && echo yes || echo no)"
env reason=BOUND interface=bcawl1 new_ip_address=10.9.9.9 new_subnet_cidr=24 sh "$MESH" 2>> "$T/err"
check "control: an event of another interface is ignored" "mgmt bhm0 brwifi5 50 10.50.0.7/24" "$(H status | grep '^mgmt')"
env reason=EXPIRE interface=bhm0 sh "$MESH" 2>> "$T/err"
check "dhcpcd EXPIRE: the lease gone" "mgmt bhm0 brwifi5 50 -" "$(H status | grep '^mgmt')"
check "the management firewall: replies, ICMP, DHCP, ports 22 80 443 on bhm0, the rest dropped" "yes yes yes yes yes" \
	"$(sed -n '/^mgmt_nft()/,/^}/p' "$MESH" | grep -q 'ct state established,related accept' && echo yes || echo no) $(grep -q 'iifname "bhm0" meta l4proto { icmp, ipv6-icmp } accept' "$MESH" && echo yes || echo no) $(grep -q 'iifname "bhm0" udp dport 68 accept' "$MESH" && echo yes || echo no) $(grep -q 'MGMT_PORTS="22, 80, 443"' "$MESH" && echo yes || echo no) $(grep -q 'iifname "bhm0" counter drop' "$MESH" && echo yes || echo no)"
: > "$PLAN"; check "status: role off (no backhaul, no bhtrunk)" "role off" "$(H status)"
echo "gt-be98-mesh-test: $pass ok, $fail failed"
[ $fail -eq 0 ]

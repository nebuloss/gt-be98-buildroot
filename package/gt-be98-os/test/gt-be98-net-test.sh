#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# Offline test of sbin/gt-be98-net, the networks' owner (owner 11-23: a
# network is an object of its own, one bridge, with 0..N SSIDs and 0..N
# ports), against the REAL sbin/gt-be98-l2 (no device, no root):
#   sh test/gt-be98-net-test.sh
# A fake `ip` keeps a fake sysfs (bridges, ports, masters) and the 802.1Q
# table, as gt-be98-l2-test.sh's; every check has a control that differs in
# one input.
set -u
here=$(cd "$(dirname "$0")" && pwd)
NETT="$here/../src/sbin/gt-be98-net"
L2="$here/../src/sbin/gt-be98-l2"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
N=$T/net
export GT_BE98_RUN="$T/run" GT_BE98_SYSNET="$N" GT_BE98_VLANCFG="$T/vlancfg" GT_BE98_PROCNET="$T/procnet" FAKE="$T" \
	GT_BE98_NETWORKS="$T/networks.conf" GT_BE98_L2="$L2" GT_BE98_WIFI_L2="$T/run/gt-be98-wifi/l2.conf" \
	GT_BE98_WIFI_CONFS="$T/wifi-ap $T/wifi" GT_BE98_NET_LAN_FOLLOW="$T/bin/lanfollow" GT_BE98_NET_ADDR_FOLLOW=
mkdir -p "$T/bin" "$T/run" "$N"
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
printf '#!/bin/sh\nexit 0\n' > "$T/bin/logger"
printf '#!/bin/sh\necho follow >> "$FAKE/follow"\n' > "$T/bin/lanfollow"
chmod +x "$T/bin/"*
PATH="$T/bin:$PATH"
pass=0 fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   $1"; else fail=$((fail + 1)); echo "FAIL $1: want [$2] got [$3]"; fi; }
ex() { [ -e "$N/$1" ] && echo yes || echo no; }
master() { m=$(readlink "$N/$1/master" 2>/dev/null); echo "${m##*/}"; }
users() { sed -n 's/^user //p' "$T/run/gt-be98-l2/$1" 2>/dev/null | tr '\n' ' '; }
NT() { sh "$NETT" "$@" 2>> "$T/err"; }
L() { sh "$L2" "$@" 2>> "$T/err"; }
st() { NT status | awk -v i="$1" '$2 == i { print $5 }'; }
mkdir -p "$N/rnr0" "$N/rnr1"; echo 1 > "$N/rnr0/flags"; echo 1 > "$N/rnr1/flags"

# 1. no list: a clean no-op
NT apply; check "no list: rc 0, nothing made" "0 0" "$? $(grep -c 'add ' "$T/iplog" 2>/dev/null || echo 0)"
# 2. a network with NEITHER an SSID NOR a port has its bridge (VLAN only:
# <trunk>.<vid> in it); a gateway network's has no trunk VLAN; Default
# (VLAN 1), a bad VLAN, a VLAN twice and an id twice are refused, the others run
cat > "$T/networks.conf" <<'X'
# /etc/gt-be98-networks.conf - written by the web UI
network=1 name=Default vlan=1 subnet= mode=vlan isolate=0 mgmt=1
network=3 name=Empty vlan=930 subnet= mode=vlan isolate=0 mgmt=1
mode=gateway vlan=940 name=Gw network=4 subnet=192.168.40.1/24 isolate=0 mgmt=1
network=5 name=Twice vlan=930 subnet=
network=6 name=Bad vlan=4095
network=3 name=Again vlan=931
network=0 name=Zero vlan=932
X
NT apply; check "apply: rc 0" 0 $?
check "network 3 (no SSID, no port): brwifi100003 with rnr0.930, user net" "yes brwifi100003 net " "$(ex brwifi100003) $(master rnr0.930) $(users brwifi100003)"
check "network 4 (gateway): brwifi100004, no rnr0.940 (the two-gateway rule, gt-be98-l2)" "yes no" "$(ex brwifi100004) $(ex rnr0.940)"
check "Default (VLAN 1), VLAN 930 twice, VLAN 4095: refused, no bridge" "refused refused refused no no no" \
	"$(st 1) $(st 5) $(st 6) $(ex brwifi100001) $(ex brwifi100005) $(ex brwifi100006)"
check "id 3 twice: the first line wins (no VLAN 931); id 0 names nothing" "no no 930" "$(ex rnr0.931) $(ex brwifi100000) $(NT status | awk '$2 == 3 { print $3 }')"
check "status: up lines with their bridge" "net 3 930 brwifi100003 up starts=1 refusals=0 why=-|net 4 940 brwifi100004 up starts=1 refusals=0 why=-|" \
	"$(NT status | grep ' up ' | tr '\n' '|')"
check "bridge <vid>: 930 -> brwifi100003; 1 none; 999 none" "brwifi100003 1 1" "$(NT bridge 930) $(NT bridge 1 > /dev/null; echo $?) $(NT bridge 999 > /dev/null; echo $?)"
check "features" "features netbridges" "$(NT features)"
n=$(grep -c 'add ' "$T/iplog")
NT apply; check "apply again: nothing made again, no start counted" "$n starts=1" "$(grep -c 'add ' "$T/iplog") $(NT status | awk '$2 == 3 { print $6 }')"
# 3. TWO SSIDs and a port on one network: the Wi-Fi's and the LAN's users
# adopt the network's bridge (one bridge, three users)
L up wifi brwifi100003 rnr0 930; L up lan brwifi100003 rnr0 930 rnr1
check "Wi-Fi and LAN join the network's bridge: users net wifi lan, rnr1.930 a member" "net wifi lan  brwifi100003" "$(users brwifi100003) $(master rnr1.930)"
mkdir -p "$N/bcawl3" "$N/bcawl3-1"; ip link set dev bcawl3 master brwifi100003; ip link set dev bcawl3-1 master brwifi100003
check "... both SSIDs' BSSes ports of it" "brwifi100003 brwifi100003" "$(master bcawl3) $(master bcawl3-1)"
# 4. delete-in-use at the OS level: the network leaves the list while its
# SSIDs still run (the web UI refuses it; a hand edit): the bridge stays for
# them (the network object lets go, wifi and lan keep it); control: network 4
# (no other user) is deleted with its bridge
sed -i '/^network=3 /d; /name=Gw/d' "$T/networks.conf"
NT apply
check "network 3 gone from the list while its SSIDs run: let go, the bridge stays (users wifi lan)" "yes wifi lan " "$(ex brwifi100003) $(users brwifi100003)"
check "control: network 4 gone, no other user: its bridge deleted" "no" "$(ex brwifi100004)"
check "status: neither listed any more (destroyed)" "" "$(NT status | awk '$2 == 3 || $2 == 4')"
# 5. a VLAN change (same id): the bridge moves, the LAN is told (follow); control: no change, no follow
printf 'network=7 name=Moves vlan=950\n' > "$T/networks.conf"; : > "$T/follow"
NT apply; ip link set dev rnr1 up 2>/dev/null; L up lan brwifi100007 rnr0 950 rnr1
check "network 7 up on 950; no follow on a first start" "brwifi100007 0" "$(master rnr0.950) $(grep -c follow "$T/follow")"
printf 'network=7 name=Moves vlan=951\n' > "$T/networks.conf"
NT apply
check "VLAN 950 -> 951: rnr0.951 in brwifi100007, rnr0.950 gone, the LAN follows once" "brwifi100007 no 1" "$(master rnr0.951) $(ex rnr0.950) $(grep -c follow "$T/follow")"
NT apply; check "control: the same list again, no follow" 1 "$(grep -c follow "$T/follow")"
printf 'network=7 name=Moves vlan=952\n' > "$T/networks.conf"; NT apply -n
check "-n (the caller reloads the LAN, gt-be98-gw): moved, no follow" "brwifi100007 1" "$(master rnr0.952) $(grep -c follow "$T/follow")"
# 6. the trunk: the Wi-Fi's effective one (its l2.conf), else the web UI's file
mkdir -p "$T/run/gt-be98-wifi"; mkdir -p "$N/rnr3"; echo 1 > "$N/rnr3/flags"
printf 'WIFI_TRUNK=rnr3\n' > "$T/wifi-ap"; printf 'network=8 name=t vlan=960\n' > "$T/networks.conf"
NT apply; check "trunk from the web UI's Wi-Fi file: rnr3.960" "brwifi100008" "$(master rnr3.960)"
printf 'WIFI_TRUNK="rnr0"\n' > "$T/run/gt-be98-wifi/l2.conf"; printf 'network=9 name=t vlan=961\n' > "$T/networks.conf"
NT apply; check "the running Wi-Fi's l2.conf wins: rnr0.961" "brwifi100009" "$(master rnr0.961)"
# 7. a MESH LEAF: no network bridge of its own (refused, let go); control: the line gone
mkdir -p "$T/run/gt-be98-wifi/gen"; echo 'bhtrunk bcawl1 10' > "$T/run/gt-be98-wifi/gen/plan"
NT apply; check "mesh leaf: refused, its bridge let go" "refused no" "$(st 9) $(ex brwifi100009)"
check "... why= says so" yes "$(NT status | grep -q 'mesh leaf' && echo yes || echo no)"
rm -f "$T/run/gt-be98-wifi/gen/plan"; NT apply
check "control: not a leaf: up again" "up yes" "$(st 9) $(ex brwifi100009)"
# 8. a refusal of gt-be98-l2 (the VLAN another bridge carries): refused, the
# others run; it runs once the VLAN is free
L up wifi brwifi12 rnr0 970
printf 'network=9 name=t vlan=961\nnetwork=10 name=c vlan=970\n' > "$T/networks.conf"
NT apply; check "VLAN 970 bridged in brwifi12 already: rc 1, network 10 refused (why from gt-be98-l2), 9 up" "1 refused up" "$? $(st 10) $(st 9)"
check "... the refusal counted once" "refusals=1" "$(NT apply; NT status | awk '$2 == 10 { print $7 }')"
L down wifi brwifi12; NT apply
check "control: brwifi12 gone: network 10 up" "up brwifi100010" "$(st 10) $(master rnr0.970)"
# 9. stop: every network's bridge let go (a user's kept)
L up lan brwifi100009 rnr0 961
NT stop; check "stop: 10 deleted (net only), 9 kept for lan, no status" "no yes lan " "$(ex brwifi100010) $(ex brwifi100009) $(users brwifi100009)"
check "... status empty" "" "$(NT status)"
# 10. the package: tool + service installed, in the default runlevel, after the Wi-Fi, before the LAN and the gateway
S="$here/.."
check "gt-be98-os.mk installs gt-be98-net (tool and service) and puts it in the default runlevel" "yes yes yes" \
	"$(grep -q 'gt-be98-mesh \\$' "$S/gt-be98-os.mk" && grep -qE '^		gt-be98-net gt-be98-addr( [a-z0-9-]+)*; do' "$S/gt-be98-os.mk" && echo yes || echo no) $(grep -q "gt-be98-gw gt-be98-net gt-be98-addr \\\\$" "$S/gt-be98-os.mk" && echo yes || echo no) $(grep -q 'gt-be98-lan gt-be98-gw gt-be98-net gt-be98-addr; do' "$S/gt-be98-os.mk" && echo yes || echo no)"
check "the service: after gt-be98-wifi, before gt-be98-lan and gt-be98-gw; features when stopped" "yes yes features|features netbridges" \
	"$(grep -q 'after gt-be98-drivers gt-be98-wifi$' "$S/src/init.d/gt-be98-net" && echo yes || echo no) $(grep -q 'before gt-be98-lan gt-be98-gw' "$S/src/init.d/gt-be98-net" && echo yes || echo no) $(GT_BE98_NET="$NETT"; extra_commands=; . "$S/src/init.d/gt-be98-net"; echo "$extra_commands|$(features)")"
echo "gt-be98-net-test: $pass ok, $fail failed"
[ $fail -eq 0 ]

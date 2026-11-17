#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# Offline test of sbin/gt-be98-l2, the one owner of the VLAN networks'
# bridges (no device, no root): sh test/gt-be98-l2-test.sh
# A fake `ip` keeps a fake sysfs (bridges, ports, masters, flags) and the
# 802.1Q table; every check has a control that differs in one input.
set -u
here=$(cd "$(dirname "$0")" && pwd)
L2="$here/../src/sbin/gt-be98-l2"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
N=$T/net
export GT_BE98_RUN="$T/run" GT_BE98_SYSNET="$N" GT_BE98_VLANCFG="$T/vlancfg" GT_BE98_PROCNET="$T/procnet" FAKE="$T"
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
"set dev "*" master "*)	x=$3; b=$5; [ -d "$N/$b/brif" ] || exit 1; [ -f "$FAKE/refuse-$x" ] && exit 1
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
chmod +x "$T/bin/"*
PATH="$T/bin:$PATH"
port() { mkdir -p "$N/$1"; echo "${2:-1}" > "$N/$1/flags"; }	# a netdev (up by default)
master() { m=$(readlink "$N/$1/master" 2>/dev/null); echo "${m##*/}"; }
users() { sed -n 's/^user //p' "$T/run/gt-be98-l2/$1" 2>/dev/null | tr '\n' ' '; }
pass=0 fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   $1"; else fail=$((fail + 1)); echo "FAIL $1: want [$2] got [$3]"; fi; }
L() { sh "$L2" "$@" 2>> "$T/err"; }

port rnr0 0; port rnr1; port rnr2
# 1. first user creates the bridge and the trunk VLAN; the trunk is brought up
L up wifi brwifi1 rnr0 921; check "up wifi: rc 0" 0 $?
check "bridge brwifi1 created" yes "$([ -d "$N/brwifi1/bridge" ] && echo yes || echo no)"
check "rnr0.921 created, VLAN 921 of rnr0, in brwifi1" "brwifi1 rnr0.921 | 921 | rnr0" "$(master rnr0.921) $(cat "$T/vlancfg")"
check "the down trunk brought up (never re-addressed)" 1 "$(cat "$N/rnr0/flags")"
check "users: wifi" "wifi " "$(users brwifi1)"
# 2. the second user adopts it: nothing created again
n=$(grep -c 'add ' "$T/iplog")
L up lan brwifi1 rnr0 921; check "up lan on the same bridge: rc 0, nothing created" "0 $n" "$? $(grep -c 'add ' "$T/iplog")"
check "users: wifi lan" "wifi lan " "$(users brwifi1)"
L up lan brwifi1 rnr0 921; check "a user recorded once" "wifi lan " "$(users brwifi1)"
# 3. a Wi-Fi stop keeps the wired members' bridge
ip link set dev rnr1 master brwifi1
L down wifi brwifi1; check "down wifi with lan left: the bridge and its VLAN stay" "yes brwifi1 lan " "$([ -d "$N/brwifi1" ] && echo yes) $(master rnr0.921) $(users brwifi1)"
# 4. one bridge per VLAN of a trunk; control: another VLAN
L up wifi brwifi2 rnr0 921; check "a VLAN another bridge carries: refused" 1 $?
check "... and nothing of brwifi2 created" no "$([ -e "$N/brwifi2" ] && echo yes || echo no)"
L up wifi brwifi2 rnr0 30; check "control: VLAN 30 on brwifi2: rc 0" 0 $?
# 5. the last user: a foreign port keeps the bridge (warned); control without it
L down lan brwifi1; check "last down with rnr1 still a port: bridge left, VLAN deleted, state gone" "yes no no" \
	"$([ -d "$N/brwifi1" ] && echo yes) $([ -e "$N/rnr0.921" ] && echo yes || echo no) $([ -e "$T/run/gt-be98-l2/brwifi1" ] && echo yes || echo no)"
check "... the warning names the port" yes "$(grep -q 'brwifi1 has port rnr1' "$T/err" && echo yes || echo no)"
ip link set dev rnr1 nomaster; ip link del dev brwifi1
L down wifi brwifi2; check "control: last down of a clean bridge: bridge and VLAN deleted" "no no" \
	"$([ -e "$N/brwifi2" ] && echo yes || echo no) $([ -e "$N/rnr0.30" ] && echo yes || echo no)"
# 6. the VLAN of a bridge changes: the old sub-interface goes, the wired
# members are evicted (never carried into another VLAN), the other users forgotten
L up lan brwifi3 rnr0 921; L up wifi brwifi3 rnr0 921; ip link set dev rnr1 master brwifi3
L up wifi brwifi3 rnr0 922; check "VLAN 921 -> 922: rc 0" 0 $?
check "... rnr0.921 deleted, rnr0.922 in brwifi3" "no brwifi3" "$([ -e "$N/rnr0.921" ] && echo yes || echo no) $(master rnr0.922)"
check "... the jack evicted, only the caller left as user" "- wifi " "$(master rnr1)- $(users brwifi3)"
check "control: the same VLAN again keeps a jack" "brwifi3" "$(L up wifi brwifi3 rnr0 922; ip link set dev rnr1 master brwifi3; L up lan brwifi3 rnr0 922; master rnr1)"
ip link set dev rnr1 nomaster; L down wifi brwifi3; L down lan brwifi3
# 7. adopted bridge and VLAN (existing before): never deleted; control above (created: deleted)
ip link add name brwifi4 type bridge stp_state 0; ip link add link rnr0 name rnr0.40 type vlan id 40
L up wifi brwifi4 rnr0 40; L down wifi brwifi4
check "an adopted bridge and VLAN survive the last down" "yes yes" "$([ -d "$N/brwifi4" ] && echo yes) $([ -e "$N/rnr0.40" ] && echo yes)"
# an existing netdev with the name but another VLAN: refused
ip link add link rnr2 name rnr0.41 type vlan id 41
L up wifi brwifi5 rnr0 41; check "rnr0.41 exists as another VLAN: refused" 1 $?
check "... and undone: no brwifi5, no state" "no no" "$([ -e "$N/brwifi5" ] && echo yes || echo no) $([ -e "$T/run/gt-be98-l2/brwifi5" ] && echo yes || echo no)"
# 8. names and values
for a in "wifi br-lan rnr0 5" "wifi brwifi rnr0 5" "wifi brwifi6x rnr0 5" "wifi brwifi6 eth0 5" "wifi brwifi6 rnr4 5" \
	"wifi brwifi6 rnr0 0" "wifi brwifi6 rnr0 4095" "wifi brwifi6 rnr0 05" "Wifi brwifi6 rnr0 5" "wifi brwifi6 rnr3 5"; do
	# shellcheck disable=SC2086
	L up $a; check "refused: up $a" 1 $?
done
L up wifi brwifi6 rnr0 5; check "control: up wifi brwifi6 rnr0 5" 0 $?
check "vid of brwifi6" 5 "$(L vid brwifi6)"
L vid brwifi7; check "vid of a bridge it does not run: rc 1" 1 $?
check "list (the adopted brwifi4 no longer run: not listed)" "brwifi6 rnr0 5 wifi|" "$(L list | tr '\n' '|')"
L up wifi brwifi6; check "usage error: rc 2" 2 $?
# 9. a failure after the bridge exists: recorded, so down undoes it
touch "$T/refuse-rnr0.7"
L up wifi brwifi7 rnr0 7; check "enslave refused: rc 1" 1 $?
check "... the failed up undid what it created" "no no" "$([ -e "$N/brwifi7" ] && echo yes || echo no) $([ -e "$N/rnr0.7" ] && echo yes || echo no)"
# 10. the wired member <wired>.<vid> (the RTL8372 jacks of VLAN V reach the
# SoC tagged V on rnr1): created with the bridge, recorded as the user's,
# removed when the user no longer names it; every check with its control
rm -f "$T/refuse-rnr0.7" "$T/refuse-rnr1.7"
wired() { sed -n 's/^wired //p' "$T/run/gt-be98-l2/$1" 2>/dev/null | tr '\n' '|'; }
ex() { [ -e "$N/$1" ] && echo yes || echo no; }
L up lan brwifi10 rnr0 921 rnr1; check "up lan with wired rnr1: rc 0" 0 $?
check "... rnr1.921 created as VLAN 921 of rnr1, in brwifi10, next to rnr0.921" "brwifi10 brwifi10 1" \
	"$(master rnr1.921) $(master rnr0.921) $(grep -c '^rnr1.921 | 921 | rnr1$' "$T/vlancfg")"
check "... recorded as lan's, made here" "lan rnr1.921 1|" "$(wired brwifi10)"
n=$(grep -c 'add ' "$T/iplog")
L up lan brwifi10 rnr0 921 rnr1; check "the same up again: rc 0, nothing created, rnr1.921 kept (not deleted and re-made)" "0 $n brwifi10 lan rnr1.921 1|" \
	"$? $(grep -c 'add ' "$T/iplog") $(master rnr1.921) $(wired brwifi10)"
check "control: no 'del' of rnr1.921 so far" 0 "$(grep -c 'del dev rnr1.921' "$T/iplog")"
L up wifi brwifi10 rnr0 921; check "another user's up (no wired): lan's rnr1.921 kept" "brwifi10 lan rnr1.921 1|" "$(master rnr1.921) $(wired brwifi10)"
L up lan brwifi10 rnr0 921; check "lan's up WITHOUT wired: rnr1.921 deleted, the bridge and rnr0.921 stay (wifi, lan users)" "no brwifi10 |lan wifi " \
	"$(ex rnr1.921) $(master rnr0.921) $(wired brwifi10)|$(users brwifi10)"
L up lan brwifi10 rnr0 921 rnr1; L down lan brwifi10
check "down lan: its rnr1.921 deleted, wifi keeps the bridge" "no yes wifi " "$(ex rnr1.921) $(ex brwifi10) $(users brwifi10)"
L up lan brwifi10 rnr0 921 rnr1; L down wifi brwifi10
check "control: down wifi keeps lan's rnr1.921" "brwifi10 lan " "$(master rnr1.921) $(users brwifi10)"
L down lan brwifi10; check "the last down: rnr1.921, rnr0.921 and the bridge deleted, no warning about rnr1.921" "no no no 0" \
	"$(ex rnr1.921) $(ex rnr0.921) $(ex brwifi10) $(grep -c 'has port rnr1.921' "$T/err")"
# refusals (and nothing left behind); control: rnr2 as the wired port
for a in "lan brwifi11 rnr0 55 rnr0" "lan brwifi11 rnr1 55 rnr1" "lan brwifi11 rnr0 55 eth0" "lan brwifi11 rnr0 55 rnr4" "lan brwifi11 rnr0 55 rnr3"; do
	# shellcheck disable=SC2086
	L up $a; check "refused: up $a (rnr0 / the trunk / not rnr1-3 / not present)" "1 no" "$? $(ex brwifi11)"
done
L up lan brwifi11 rnr0 55 rnr2; check "control: up lan brwifi11 rnr0 55 rnr2" "0 brwifi11" "$? $(master rnr2.55)"
L down lan brwifi11
# the bridge's VLAN moves: the wired member of the old VLAN goes
L up lan brwifi12 rnr0 30 rnr1; L up wifi brwifi12 rnr0 31
check "VLAN 30 -> 31: rnr1.30 deleted, no wired record, only wifi left" "no |wifi " "$(ex rnr1.30) $(wired brwifi12)|$(users brwifi12)"
L down wifi brwifi12
# adopted (existing before): released, never deleted
ip link add link rnr1 name rnr1.40 type vlan id 40
L up lan brwifi13 rnr0 40 rnr1; check "adopted rnr1.40: enslaved, recorded made 0" "brwifi13 lan rnr1.40 0|" "$(master rnr1.40) $(wired brwifi13)"
L down lan brwifi13; check "... the last down releases it (no master), never deletes it" "yes -" "$(ex rnr1.40) $(master rnr1.40)-"
ip link add link rnr2 name rnr1.43 type vlan id 43
L up lan brwifi13 rnr0 43 rnr1; check "rnr1.43 exists as a VLAN of another port: refused, undone" "1 no no" "$? $(ex brwifi13) $(ex rnr0.43)"
# the wired member is a port of another bridge: refused
ip link add name brx type bridge stp_state 0; ip link add link rnr1 name rnr1.42 type vlan id 42; ip link set dev rnr1.42 master brx
L up lan brwifi14 rnr0 42 rnr1; check "rnr1.42 is a port of brx: refused, nothing made" "1 no brx" "$? $(ex brwifi14) $(master rnr1.42)"
# a failure after the wired member exists: the failed up deletes it
touch "$T/refuse-rnr1.7"
L up lan brwifi15 rnr0 7 rnr1; check "enslave of rnr1.7 refused: rc 1, rnr1.7, rnr0.7 and the bridge undone" "1 no no no" "$? $(ex rnr1.7) $(ex rnr0.7) $(ex brwifi15)"
rm -f "$T/refuse-rnr1.7"
L up lan brwifi15 rnr0 7 rnr1; check "control: the same up once the enslave works" "0 brwifi15" "$? $(master rnr1.7)"
# a network WITHOUT an SSID: gt-be98-lan's own bridge brwifi<100000 + id>, lan its only user
L up lan brwifi100003 rnr0 930 rnr1; check "a network without an SSID: brwifi100003 on rnr0.930 with rnr1.930" "0 brwifi100003 brwifi100003 lan " "$? $(master rnr0.930) $(master rnr1.930) $(users brwifi100003)"
port rnr3; ip link set dev rnr3 master brwifi100003
# its SSID appears: the Wi-Fi's bridge takes VLAN 930 over (lan's reload re-attaches the jacks)
L up wifi brwifi8 rnr0 930; check "the SSID's brwifi8 takes 930 over from the lan-only brwifi100003" "0 brwifi8 no no no -" \
	"$? $(master rnr0.930) $(ex brwifi100003) $(ex rnr1.930) $([ -e "$T/run/gt-be98-l2/brwifi100003" ] && echo yes || echo no) $(master rnr3)-"
check "... the move is logged" yes "$(grep -q 'rnr0.930 moves from brwifi100003' "$T/err" && echo yes || echo no)"
L up lan brwifi8 rnr0 930 rnr1; check "... and lan joins brwifi8 with rnr1.930: one bridge, both users" "0 brwifi8 wifi lan " "$? $(master rnr1.930) $(users brwifi8)"
# controls: no takeover by lan, of a Wi-Fi-numbered bridge, or of a bridge the Wi-Fi uses too
L up lan brwifi100004 rnr0 931; L up lan brwifi100005 rnr0 931; check "control: lan asking for a VLAN another lan-only bridge holds: refused" 1 $?
L up wifi brwifi100004 rnr0 931; L up wifi brwifi9 rnr0 931; check "control: a lan-only bridge the Wi-Fi also uses (users lan wifi): refused" 1 $?
L down wifi brwifi100004
L up lan brwifi20 rnr0 932; L up wifi brwifi21 rnr0 932; check "control: a lan-only brwifi20 (a Wi-Fi number, test 4's case): refused" 1 $?
# 11. GATEWAY NETWORKS (the two-gateway rule): a network whose line says
# mode=gateway has no trunk sub-interface; every check with its control
export GT_BE98_NETWORKS="$T/networks.conf"
st() { sed -n "s/^$2 //p" "$T/run/gt-be98-l2/$1" 2>/dev/null; }
printf '# comment\nnetwork=4 name=Lab vlan=44 subnet=192.168.40.1/24 mode=gateway isolate=0 mgmt=1\nnetwork=3 name=Up vlan=30 subnet=192.168.30.1/24\nnetwork=5 name=V vlan=50 subnet= mode=vlan\n' > "$GT_BE98_NETWORKS"
check "mode 44 (mode=gateway)" gateway "$(L mode 44)"
check "control: mode 30 (a subnet, no mode=: VLAN only, D-GW1)" vlan "$(L mode 30)"
check "control: mode 50 (mode=vlan)" vlan "$(L mode 50)"
check "control: mode 41 (no line)" vlan "$(L mode 41)"
L up lan brwifi100004 rnr0 44 rnr1; check "up on a gateway VLAN: rc 0, bridge with rnr1.44, NO rnr0.44" "0 brwifi100004 no" "$? $(master rnr1.44) $(ex rnr0.44)"
check "... state: trunk -, uplink rnr0" "- rnr0" "$(st brwifi100004 trunk) $(st brwifi100004 uplink)"
check "... list shows trunk -" "brwifi100004 - 44 lan" "$(L list | grep '^brwifi100004')"
L up lan brwifi30 rnr0 30 rnr1; check "control: VLAN 30 (VLAN only) gets rnr0.30" "0 brwifi30" "$? $(master rnr0.30)"
# a second user (the SSID's bridge takes the VLAN over): still no trunk
L up wifi brwifi9 rnr0 44; check "the SSID's bridge takes gateway VLAN 44 over: rc 0, no rnr0.44" "0 no no" "$? $(ex rnr0.44) $(ex brwifi100004)"
check "... one bridge per VLAN still holds on a gateway VLAN (another Wi-Fi bridge refused)" 1 "$(L up wifi brwifi19 rnr0 44; echo $?)"
L up lan brwifi9 rnr0 44 rnr1; port rnr3; ip link set dev rnr3 master brwifi9
# mode switch gateway -> vlan via sync: ONLY the trunk sub-interface comes; members stay
sed -i 's/ mode=gateway / mode=vlan /' "$GT_BE98_NETWORKS"
L sync; check "sync, 44 now VLAN only: rc 0, rnr0.44 created in brwifi9" "0 brwifi9" "$? $(master rnr0.44)"
check "... the wired member, the bare jack and both users stay" "brwifi9 brwifi9 wifi lan " "$(master rnr1.44) $(master rnr3) $(users brwifi9)"
check "... state: trunk rnr0" rnr0 "$(st brwifi9 trunk)"
# and back: vlan -> gateway via sync, members stay
sed -i 's/ mode=vlan isolate/ mode=gateway isolate/' "$GT_BE98_NETWORKS"
L sync; check "sync, 44 a gateway again: rnr0.44 deleted (made here), members stay" "0 no brwifi9 brwifi9 -" "$? $(ex rnr0.44) $(master rnr1.44) $(master rnr3) $(st brwifi9 trunk)"
check "control: sync left VLAN 30's rnr0.30 alone" brwifi30 "$(master rnr0.30)"
# mode switch by `up` (gt-be98-lan's reload): vlan -> gateway keeps the members
sed -i 's/vlan=30 subnet=192.168.30.1\/24$/vlan=30 subnet=192.168.30.1\/24 mode=gateway/' "$GT_BE98_NETWORKS"
L up lan brwifi30 rnr0 30 rnr1; check "up after 30 became a gateway: rnr0.30 removed, rnr1.30 kept, no eviction" "0 no brwifi30 lan " "$? $(ex rnr0.30) $(master rnr1.30) $(users brwifi30)"
check "... no 'evicted' message for brwifi30" 0 "$(grep -c 'evicted from brwifi30' "$T/err")"
# gt-be98-gw holds a bridge: the trunk stays out even when the file says VLAN only
sed -i 's/ mode=gateway$//' "$GT_BE98_NETWORKS"
mkdir -p "$T/run/gt-be98-gw/hold"; : > "$T/run/gt-be98-gw/hold/brwifi30"
check "mode 30 with gt-be98-gw holding brwifi30: gateway" gateway "$(L mode 30 brwifi30)"
check "control: mode 30 of another bridge: vlan" vlan "$(L mode 30 brwifi31)"
L sync; check "sync while held: still no rnr0.30" "no -" "$(ex rnr0.30) $(st brwifi30 trunk)"
mkdir -p "$T/procnet/ipv6/conf/brwifi30"; echo 0 > "$T/procnet/ipv6/conf/brwifi30/disable_ipv6"
L up lan brwifi30 rnr0 30 rnr1; check "up while held: still no rnr0.30" "0 no" "$? $(ex rnr0.30)"
check "up while held: the bridge's IPv6 left to gt-be98-gw (disable_ipv6 not rewritten)" 0 "$(cat "$T/procnet/ipv6/conf/brwifi30/disable_ipv6")"
rm -f "$T/run/gt-be98-gw/hold/brwifi30"
L up lan brwifi30 rnr0 30 rnr1; check "control: up when not held: IPv6 off on the bridge (disable_ipv6=1)" 1 "$(cat "$T/procnet/ipv6/conf/brwifi30/disable_ipv6")"
L sync; check "released, then sync: rnr0.30 carried again, rnr1.30 kept" "0 brwifi30 brwifi30" "$? $(master rnr0.30) $(master rnr1.30)"
# the last down of a gateway bridge: nothing of a trunk to delete, bridge gone
L down wifi brwifi9; ip link set dev rnr3 nomaster; L down lan brwifi9
check "last down of a gateway bridge: bridge and rnr1.44 deleted, state gone" "no no no" "$(ex brwifi9) $(ex rnr1.44) $([ -e "$T/run/gt-be98-l2/brwifi9" ] && echo yes || echo no)"
# a gateway bridge does not hold rnr0.<vid> even when an rnr0.44 exists (adopted by nobody)
ip link add link rnr0 name rnr0.44 type vlan id 44
L up lan brwifi100004 rnr0 44; check "an rnr0.44 that exists is never enslaved into a gateway bridge" "0 -" "$? $(master rnr0.44)-"
L down lan brwifi100004; ip link del dev rnr0.44
# a state written before the uplink line existed: uplink = trunk
printf 'trunk rnr0\nvid 60\nmade_bridge 0\nmade_vlan 0\nuser lan\n' > "$T/run/gt-be98-l2/brwifi60"
check "an old state (no uplink line) lists as before" "brwifi60 rnr0 60 lan" "$(L list | grep '^brwifi60')"
rm -f "$T/run/gt-be98-l2/brwifi60"
# 12. THE MESH BACKHAUL (buildroot docs/MESH-BACKHAUL-DESIGN.md): the root's
# downlink trunks bh<k> (a leaf's AP_VLAN) and the leaf's uplink trunk bhs
bhs_() { sed -n 's/^bh //p' "$T/run/gt-be98-l2/$1" 2>/dev/null | tr '\n' ' '; }
printf 'network=4 name=Lab vlan=44 subnet=192.168.40.1/24 mode=gateway bhvid=444\nnetwork=3 name=Up vlan=33\nnetwork=7 name=B vlan=70 bhvid=0\n' > "$GT_BE98_NETWORKS"
L up wifi brwifi41 rnr0 44; L up wifi brwifi31 rnr0 33
port bcawl0-1.sta1
L trunk-add bcawl0-1.sta1 02:00:00:00:00:AA > "$T/out"; check "trunk-add: rc 0, alias bh0 printed" "0 bh0" "$? $(cat "$T/out")"
check "... bh0.33 (VLAN 33, no bhvid) in brwifi31, VLAN 33 of the AP_VLAN" "brwifi31 yes" "$(master bh0.33) $(grep -q '^bh0.33 | 33 | bcawl0-1.sta1$' "$T/vlancfg" && echo yes || echo no)"
check "... the gateway network 44 carried on its bhvid=444: bh0.444 in brwifi41" "brwifi41" "$(master bh0.444)"
check "... no bh0.44 (the bhvid wins)" no "$(ex bh0.44)"
check "... recorded as made members" "bh0.33 1 |bh0.444 1 " "$(bhs_ brwifi31)|$(bhs_ brwifi41)"
check "... the untagged AP_VLAN is no bridge port" "-" "$(master bcawl0-1.sta1)-"
check "trunks: bh0 bcawl0-1.sta1 down 02:00:00:00:00:aa (lower case)" "bh0 bcawl0-1.sta1 down 02:00:00:00:00:aa" "$(L trunks)"
L trunk-add bcawl0-1.sta1 > "$T/out"; check "trunk-add of the same dev again: the same alias, nothing new" "0 bh0 brwifi31" "$? $(cat "$T/out") $(master bh0.33)"
# a bridge that comes later gets the downlink at its up
L up wifi brwifi71 rnr0 70; check "a bridge made after the link: bh0.70 (bhvid=0 is not a VID: its vlan=) at its up" "0 brwifi71" "$? $(master bh0.70)"
# a second link: bh1
port bcawl0-1.sta2
L trunk-add bcawl0-1.sta2 > "$T/out"; check "a second link: bh1, bh1.33 in brwifi31" "bh1 brwifi31 brwifi31" "$(cat "$T/out") $(master bh1.33) $(master bh0.33)"
# the leaf's bridges (uplink bhs) never get a downlink: no loop on a box
port bcawl1
L up wifi brwifi131 bhs 33; check "up on bhs without an uplink: refused" 1 $?
L uplink bcawl1; check "uplink bcawl1: rc 0, trunks lists bhs up" "0 bhs bcawl1 up -" "$? $(L trunks | grep '^bhs')"
L up wifi brwifi131 bhs 33; check "leaf bridge brwifi131 on bhs.33: bhs.33 = VLAN 33 of bcawl1, in brwifi131" "0 brwifi131 yes" \
	"$? $(master bhs.33) $(grep -q '^bhs.33 | 33 | bcawl1$' "$T/vlancfg" && echo yes || echo no)"
check "... the leaf bridge got NO downlink (bh0/bh1 stay in brwifi31 only)" "|brwifi31 brwifi31" "$(bhs_ brwifi131)|$(master bh0.33) $(master bh1.33)"
check "... the leaf's station is no bridge port" "-" "$(master bcawl1)-"
check "control: the root bridge on rnr0.33 keeps its uplink" brwifi31 "$(master rnr0.33)"
# the station moves to another radio: bhs.33 follows
port bcawl2
L uplink bcawl2; check "uplink moves to bcawl2: bhs.33 now VLAN 33 of bcawl2, in brwifi131" "0 brwifi131 yes no" \
	"$? $(master bhs.33) $(grep -q '^bhs.33 | 33 | bcawl2$' "$T/vlancfg" && echo yes || echo no) $(grep -q '^bhs.33 | 33 | bcawl1$' "$T/vlancfg" && echo yes || echo no)"
L down wifi brwifi131; check "leaf bridge down: bhs.33 deleted" "no no" "$(ex bhs.33) $(ex brwifi131)"
L uplink -; check "uplink -: no bhs trunk" "" "$(L trunks | grep '^bhs')"
# bhvid moved: sync moves the downlinks
sed -i 's/bhvid=444/bhvid=445/' "$GT_BE98_NETWORKS"
L sync; check "sync after bhvid 444 -> 445: bh0.445 and bh1.445 in brwifi41, bh0.444 gone" "brwifi41 brwifi41 no" "$(master bh0.445) $(master bh1.445) $(ex bh0.444)"
# two bridges wanting one backhaul VID: the second is not carried
sed -i 's/bhvid=445/bhvid=33/' "$GT_BE98_NETWORKS"
L sync; check "bhvid=33 = VLAN 33's VID: sync rc 1, brwifi41 not carried, brwifi31 keeps bh0.33" "1 brwifi31 -" "$? $(master bh0.33) $(bhs_ brwifi41)-"
check "... logged" yes "$(grep -q 'backhaul VID 33 is carried for brwifi31 already' "$T/err" && echo yes || echo no)"
sed -i 's/bhvid=33/bhvid=444/' "$GT_BE98_NETWORKS"; L sync
check "control: bhvid back to 444: carried again" brwifi41 "$(master bh0.444)"
# the link goes: its VLANs go, the other link's stay
L trunk-del bcawl0-1.sta1 > "$T/out"; check "trunk-del: rc 0, bh0 freed, its VLANs deleted, bh1's kept" "0 bh0 no no no brwifi31" \
	"$? $(cat "$T/out") $(ex bh0.33) $(ex bh0.444) $(ex bh0.70) $(master bh1.33)"
check "... trunks lists bh1 only" "bh1 bcawl0-1.sta2 down -" "$(L trunks)"
L trunk-add bcawl0-1.sta1 > "$T/out"; check "a link again: the lowest free alias bh0" "bh0 brwifi31" "$(cat "$T/out") $(master bh0.33)"
# refusals
check "trunk-add of an absent dev: refused" 1 "$(L trunk-add bcawl0-1.sta9 > /dev/null; echo $?)"
check "trunk-add of a wired port: refused" 1 "$(L trunk-add rnr0 > /dev/null; echo $?)"
check "trunk-add with a bad peer: refused" 1 "$(port bcawl0-1.sta3; L trunk-add bcawl0-1.sta3 nomac > /dev/null; echo $?)"
for k in 3 4 5 6 7 8 9; do port bcawl0-1.sta1$k; L trunk-add bcawl0-1.sta1$k > /dev/null; done
check "a 9th link: refused (8 aliases)" 1 "$(L trunk-add bcawl0-1.sta3 > /dev/null; echo $?)"
for k in 3 4 5 6 7 8 9; do L trunk-del bcawl0-1.sta1$k > /dev/null; done
# the last user of a root bridge: its backhaul VLANs go with it
L down wifi brwifi71; check "last down of brwifi71: bh0.70 and bh1.70 deleted, bridge gone" "no no no" "$(ex bh0.70) $(ex bh1.70) $(ex brwifi71)"
# the VLAN of a root bridge changes: the downlinks follow
L up wifi brwifi31 rnr0 32; check "brwifi31 VLAN 33 -> 32: bh0.32 and bh1.32 in it, bh0.33 gone" "0 brwifi31 brwifi31 no" "$? $(master bh0.32) $(master bh1.32) $(ex bh0.33)"
echo "gt-be98-l2-test: $pass ok, $fail failed"
[ $fail -eq 0 ]

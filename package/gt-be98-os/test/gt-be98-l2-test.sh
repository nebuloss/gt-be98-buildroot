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
echo "gt-be98-l2-test: $pass ok, $fail failed"
[ $fail -eq 0 ]

#!/bin/sh
# shellcheck shell=busybox
# SPDX-License-Identifier: GPL-2.0
# Offline test of sbin/gt-be98-netguard's sweep (no device, no root):
#   sh test/gt-be98-netguard-test.sh [OLD_NETGUARD]
# A fake sysfs tree (GT_BE98_SYSNET: <bridge>/brif/<port>, <port>/brport/
# {hairpin_mode,isolated}, <port>/master) and fakes of ip and logger (PATH).
# 1. the sweep's actions on a tree with one case of every rule;
# 2. given OLD_NETGUARD (a former version, e.g. from git show): the same
#    actions as that version on the same tree (its /sys/class/net replaced);
# 3. the cost: a sweep of a compliant tree runs no external command (PATH =
#    counting wrappers), with its control (a hairpin to turn off: no fork
#    either, it is a write) and, with strace, forks nothing.
set -u
here=$(cd "$(dirname "$0")" && pwd)
G="$here/../src/sbin/gt-be98-netguard"
SH=${SH:-sh}
# busybox sh runs its own ip and logger applets before PATH: the fakes would
# not be used (and ip would act on this machine). The image's /bin/sh is bash.
case "$SH" in *busybox*) echo "skip: SH=$SH (applets before PATH; run with sh or bash)"; exit 0 ;; esac
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0 n=0
check() {
	n=$((n + 1))
	if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want [$2] got [$3]"; fail=1; fi
}
S="$T/net"; mkdir -p "$T/bin" "$S" "$T/run"
printf '#!/bin/sh\necho "ip $*" >> "%s/acts"\n' "$T" > "$T/bin/ip"
printf '#!/bin/sh\nshift 3; echo "log $*" >> "%s/acts"\n' "$T" > "$T/bin/logger"
chmod +x "$T/bin/"*
port() {	# port BRIDGE PORT HAIRPIN ISOLATED
	mkdir -p "$S/$2/brport" "$S/$1/brif"
	echo "$3" > "$S/$2/brport/hairpin_mode"; echo "$4" > "$S/$2/brport/isolated"
	ln -sfn "../$1" "$S/$2/master"; ln -sfn "../../$2/brport" "$S/$1/brif/$2"
}
tree() {	# the case tree: one port per rule
	rm -rf "$S"; mkdir -p "$S/lo"
	port brwifi1 bcawl0 1 0		# kept, hairpin on -> off
	port brwifi1 bcawl3 0 0		# kept
	port brwifi1 rnr0.921 0 0		# the listed trunk VLAN: kept
	port brwifi1 rnr0.30 0 0		# not listed: detached
	port brwifi1 bcawl5 0 0		# a station: detached
	port brwifi2 bcawl1 0 0		# isolated bridge: isolated -> 1
	port brwifi2 rnr0.31 0 1		# trunk VLAN of brwifi2 isolated: -> 0
	port br-lan rnr1 0 0			# a LAN port: kept
	port br-lan rnr2 0 0			# not listed: detached
	port brx rnr0 0 0			# the uplink in a bridge: detached
	port brwifi60 bcawl6 0 1		# the repeater in its bridge: kept, never isolated -> 0
	port brwifi60 rnr0.60 0 0		# a VLAN in a repeater bridge: detached
}
printf 'WIFI_TRUNK="rnr0"\nWIFI_VLANS="brwifi1:921 brwifi2:31 brwifi60:60"\nWIFI_ISOLATE="brwifi2 brwifi60"\n' > "$T/l2.conf"
printf 'LAN_PORTS="rnr1"\nLAN_BRIDGE=br-lan\n' > "$T/lan.conf"
printf 'bcawl5\nbcawl6\n' > "$T/stations"; echo 'bcawl6 brwifi60' > "$T/repeaters"
export GT_BE98_SYSNET="$S" GT_BE98_WIFI_L2="$T/l2.conf" GT_BE98_LAN_CONF="$T/lan.conf" \
	GT_BE98_WIFI_STATIONS="$T/stations" GT_BE98_WIFI_REPEATERS="$T/repeaters" GT_BE98_RUN="$T/run"
state() {	# the actions (sorted) and every brport value afterwards
	sort "$T/acts"
	for f in "$S"/*/brport/*; do echo "${f#"$S"/} $(cat "$f")"; done
}
tree; : > "$T/acts"; PATH="$T/bin:$PATH" $SH "$G" --sweep; state > "$T/new.txt"
check "detached: rnr0.30 (not listed), bcawl5 (station), rnr2 (not a LAN port), rnr0 (uplink), rnr0.60 (repeater bridge)" \
	"ip link set bcawl5 nomaster|ip link set rnr0 nomaster|ip link set rnr0.30 nomaster|ip link set rnr0.60 nomaster|ip link set rnr2 nomaster" \
	"$(grep '^ip ' "$T/new.txt" | tr '\n' '|' | sed 's/|$//')"
check "kept: bcawl0 bcawl1 bcawl3 bcawl6 rnr0.921 rnr0.31 rnr1 never detached" "0" "$(grep -cE ' (bcawl[0136]|rnr0\.921|rnr0\.31|rnr1) nomaster' "$T/acts")"
check "hairpin turned off on bcawl0" "bcawl0/brport/hairpin_mode 0" "$(grep '^bcawl0/brport/hairpin' "$T/new.txt")"
check "isolation: bcawl1 -> 1, rnr0.31 -> 0, bcawl6 (repeater) -> 0" \
	"bcawl1/brport/isolated 1|bcawl6/brport/isolated 0|rnr0.31/brport/isolated 0" \
	"$(grep -E '^(bcawl1|bcawl6|rnr0.31)/brport/isolated' "$T/new.txt" | tr '\n' '|' | sed 's/|$//')"
check "every action logged (5 detached, 1 hairpin, 3 isolation)" "9" "$(grep -c '^log ' "$T/acts")"
# 1b. multicast-to-unicast (rule 5): BSS ports follow WIFI_MCAST_TO_UNICAST
# (default 1), the repeater's uplink is 0, a trunk VLAN is never touched, a
# port without the attribute is left alone (none created)
mtree() {
	rm -rf "$S"; mkdir -p "$S/lo"
	port brwifi1 bcawl0 0 0; echo 0 > "$S/bcawl0/brport/multicast_to_unicast"
	port brwifi1 bcawl3 0 0					# no attribute
	port brwifi1 rnr0.921 0 0; echo 0 > "$S/rnr0.921/brport/multicast_to_unicast"
	port brwifi60 bcawl6 0 0; echo 1 > "$S/bcawl6/brport/multicast_to_unicast"
	port brwifi60 bcawl2-1 0 0; echo 0 > "$S/bcawl2-1/brport/multicast_to_unicast"
}
mv_() { for p in bcawl0 rnr0.921 bcawl6 bcawl2-1; do printf '%s=%s ' "$p" "$(cat "$S/$p/brport/multicast_to_unicast")"; done; ls "$S/bcawl3/brport" | tr '\n' ' '; }
mtree; : > "$T/acts"; PATH="$T/bin:$PATH" $SH "$G" --sweep
check "m2u (l2.conf without the key: default 1): BSS ports 1, repeater uplink 0, trunk VLAN untouched, no attribute created" \
	"bcawl0=1 rnr0.921=0 bcawl6=0 bcawl2-1=1 hairpin_mode isolated " "$(mv_)"
check "m2u: each change logged (3)" "3" "$(grep -c '^log multicast_to_unicast=' "$T/acts")"
cp "$T/l2.conf" "$T/l2.conf.keep"; echo 'WIFI_MCAST_TO_UNICAST="0"' >> "$T/l2.conf"
: > "$T/acts"; PATH="$T/bin:$PATH" $SH "$G" --sweep
check "m2u control: WIFI_MCAST_TO_UNICAST=0 turns the BSS ports off" "bcawl0=0 rnr0.921=0 bcawl6=0 bcawl2-1=0 " "$(mv_ | cut -d' ' -f1-4) "
echo 'WIFI_MCAST_TO_UNICAST="1"' >> "$T/l2.conf"
mtree; echo 1 > "$S/bcawl0/brport/multicast_to_unicast"; echo 0 > "$S/bcawl6/brport/multicast_to_unicast"; echo 1 > "$S/bcawl2-1/brport/multicast_to_unicast"
: > "$T/acts"; PATH="$T/bin:$PATH" $SH "$G" --sweep
check "m2u: a compliant tree changes nothing (the last WIFI_MCAST_TO_UNICAST line wins)" "0" "$(grep -c multicast_to_unicast "$T/acts")"
cp "$T/l2.conf.keep" "$T/l2.conf"
# 2. the same actions as a former version
if [ -n "${1:-}" ]; then
	sed "s|/sys/class/net|$S|g" "$1" > "$T/old"
	# the former version has no --sweep: its functions, then one sweep
	tree; : > "$T/acts"
	sed -n '1,/^\[ "\${1:-}" = --selftest \]/p' "$T/old" | sed '$d' > "$T/old.lib"
	printf '. "%s"\nsweep\n' "$T/old.lib" > "$T/old.run"
	PATH="$T/bin:$PATH" $SH "$T/old.run" 2>/dev/null; state > "$T/old.txt"
	check "the same actions and brport values as $(basename "$1")" "same" "$(cmp -s "$T/old.txt" "$T/new.txt" && echo same || diff "$T/old.txt" "$T/new.txt" | tr '\n' ' ')"
fi
# 3. the cost
mkdir -p "$T/cnt"; : > "$T/execs"
for c in ip logger cat sed awk grep tail head tr readlink sleep mkfifo rm; do
	r=$(command -v "$c" 2>/dev/null) || continue
	[ -x "$T/bin/$c" ] && r="$T/bin/$c"
	printf '#!/bin/sh\necho %s >> "%s"\nexec %s "$@"\n' "$c" "$T/execs" "$r" > "$T/cnt/$c"
done
chmod +x "$T/cnt/"*
clean() { rm -rf "$S"; mkdir -p "$S"; port brwifi1 bcawl0 0 0; port brwifi1 bcawl3 0 0; port brwifi1 rnr0.921 0 0; port brwifi2 bcawl1 0 1; port br-lan rnr1 0 0; }
BS=$(command -v "${SH%% *}"); [ "${SH#* }" != "$SH" ] && BS="$BS ${SH#* }"
clean; : > "$T/execs"; : > "$T/acts"; PATH="$T/cnt" $BS "$G" --sweep
check "cost: a sweep of a compliant tree runs no external command, changes nothing" "0 0" "$(wc -l < "$T/execs" | tr -d ' ') $(wc -l < "$T/acts" | tr -d ' ')"
echo 1 > "$S/bcawl3/brport/hairpin_mode"; : > "$T/execs"; PATH="$T/cnt" $BS "$G" --sweep
check "cost control: a hairpin to turn off: turned off, logged (one logger)" "logger 0" "$(tr '\n' ' ' < "$T/execs")$(cat "$S/bcawl3/brport/hairpin_mode")"
if ST=$(command -v strace 2>/dev/null); then
	clean; PATH="$T/cnt" $ST -f -qq -e trace=clone,clone3,fork,vfork -o "$T/st" $BS "$G" --sweep
	check "cost (strace): a compliant sweep forks nothing" "0" "$(grep -cE '^[0-9]+ +(clone|clone3|fork|vfork)\(' "$T/st")"
fi
# 4. VLAN jacks (gt-be98-lan LAN_PORT_rnr2/3, LAN_JACK_4..7 as rnr1.<vid>) and the BPDU guard
rm -rf "$S"; mkdir -p "$S/lo" "$T/run/gt-be98-l2"
printf 'trunk rnr0\nvid 921\nmade_bridge 1\nmade_vlan 1\nuser lan\nwired lan rnr1.921 1\n' > "$T/run/gt-be98-l2/brwifi1"
printf 'trunk rnr0\nvid 31\nmade_bridge 1\nmade_vlan 1\nuser wifi\n' > "$T/run/gt-be98-l2/brwifi2"
port brwifi1 rnr0.921 0 0
port brwifi1 rnr2 0 0		# native 921, the bridge on rnr0.921: kept
port brwifi2 rnr3 0 0		# native 921, but brwifi2 runs VLAN 31: detached
port brwifi1 rnr1 0 0		# bare rnr1 (the RC9 way): never any more: detached
port brwifi1 rnr1.921 0 0	# the 2.5G jacks of VLAN 921, gt-be98-l2's wired member: kept
port brwifi2 rnr1.31 0 0	# not recorded by gt-be98-l2: detached
printf 'LAN_PORT_rnr1="native=921 tagged=none"\nLAN_PORT_rnr2="native=921"\nLAN_PORT_rnr3="native=921"\nLAN_JACK_6="native=921 tagged=none enabled=1"\n' > "$T/lan.conf"
for p in rnr2 rnr3; do echo 3 > "$S/$p/brport/state"; done
cat > "$T/bin/nft" <<X
#!/bin/sh
echo "nft \$*" >> "$T/acts"
cat "$T/counters" 2>/dev/null
X
cat > "$T/bin/bridge" <<X
#!/bin/sh
echo "bridge \$*" >> "$T/acts"
[ "\$1 \$2 \$3" = "link set dev" ] && [ "\$5" = state ] && echo "\$6" > "$S/\$4/brport/state"
exit 0
X
chmod +x "$T/bin/nft" "$T/bin/bridge"
: > "$T/acts"; PATH="$T/bin:$PATH" sh "$G" --sweep
check "VLAN jack rnr2 and the jacks' rnr1.921 kept; another VLAN's bridge, bare rnr1 and an unrecorded rnr1.31 detached" \
	"ip link set rnr1 nomaster|ip link set rnr1.31 nomaster|ip link set rnr3 nomaster|" "$(grep '^ip ' "$T/acts" | sort | tr '\n' '|')"
check "no guard loaded (gt-be98-lan applied nothing): nft never run" "0" "$(grep -c '^nft ' "$T/acts")"
printf 'vport rnr2 brwifi1 921\nguard\njack 4 brwifi1 921\njack 6 brwifi1 921\njack 5 brwifi9 30\n' > "$T/run/gt-be98-lan.applied"
# what `nft list table bridge gt_be98_lan_guard` prints ($1: the elements of bpdu_src_921, "" none)
counters() {
	printf 'table bridge gt_be98_lan_guard {\n\tcounter bpdu_in_rnr2 {\n\t\tpackets %s bytes 0\n\t}\n' "$1"
	printf '\tcounter bpdu_in_rnr1_921 {\n\t\tpackets 0 bytes 0\n\t}\n\tcounter bpdu_out_rnr0_921 {\n\t\tpackets 4 bytes 152\n\t}\n'
	printf '\tset tripped {\n\t\ttype ifname\n\t\tsize 65535\n\t\tflags dynamic\n\t}\n'
	printf '\tset bpdu_src_30 {\n\t\ttype ether_addr\n\t\tsize 65535\n\t\tflags dynamic\n\t}\n'
	printf '\tset bpdu_src_921 {\n\t\ttype ether_addr\n\t\tsize 65535\n\t\tflags dynamic\n'
	[ -n "$2" ] && printf '\t\telements = { %s }\n' "$2"
	printf '\t}\n\tchain jack_in {\n\t\ttype filter hook prerouting priority -200; policy accept;\n\t\tiifname @tripped drop\n\t}\n}\n'
}
counters 0 "" > "$T/counters"
: > "$T/acts"; PATH="$T/bin:$PATH" sh "$G" --sweep
check "guard loaded, counters 0, no BPDU source: one nft (list table), nothing latched, rnr2 and rnr1.921 kept" "1 nft list table bridge gt_be98_lan_guard no 0" \
	"$(grep -c '^nft ' "$T/acts") $(grep '^nft ' "$T/acts") $([ -s "$T/run/gt-be98-lan.tripped" ] && echo yes || echo no) $(grep -c '^ip link set rnr\(2\|1.921\) nomaster' "$T/acts")"
counters 1 "" > "$T/counters"
: > "$T/acts"; PATH="$T/bin:$PATH" sh "$G" --sweep
check "the counter of rnr2 moved: rnr2 latched and DETACHED (nomaster: FDB flush + the Runner's flows of the port dropped), logged, no port-state call; rnr1.921 kept" "rnr2 1 yes 0 0" \
	"$(cat "$T/run/gt-be98-lan.tripped") $(grep -c '^ip link set rnr2 nomaster' "$T/acts") $(grep -q 'log .*BPDU guard: a BPDU entered from rnr2' "$T/acts" && echo yes) $(grep -c '^bridge link set' "$T/acts") $(grep -c 'rnr1.921 nomaster' "$T/acts")"
: > "$T/acts"; PATH="$T/bin:$PATH" sh "$G" --sweep
check "a latched port found in a bridge again (re-attached by anything): detached again, latched once" "1 1" "$(grep -c '^ip link set rnr2 nomaster' "$T/acts") $(grep -c . "$T/run/gt-be98-lan.tripped")"
rm -f "$T/run/gt-be98-lan.tripped"; counters 0 "" > "$T/counters"
: > "$T/acts"; PATH="$T/bin:$PATH" sh "$G" --sweep
check "control: the latch cleared (gt-be98-lan restart), counter 0: rnr2 kept in its native bridge" "0" "$(grep -c '^ip link set rnr2 nomaster' "$T/acts")"
# 4b. a BPDU source on rnr1.921: attributed through the driver's l2_lookup
# (a fake driver directory; its l2_lookup answers from a table), the jacks
# latched into jack_block; rnr1.921 itself stays (the other jacks of the VLAN)
R="$T/rtl"; mkdir -p "$R"; echo 0x0 > "$R/jack_block"; : > "$R/l2_lookup"; : > "$R/jack_profiles"
sed -n '1,/^\[ "\${1:-}" = --selftest \]/p' "$G" | sed '$d' > "$T/ng.lib"
cat > "$T/ng.run" <<X
. "$T/ng.lib"
# the driver's answer: the table's line for "<mac> <vid>", else "<mac> <vid> none"
l2_lookup() { echo "\$1 \$2" >> "$T/lookups"; [ -e "$T/l2table" ] || return 1; lk_parse "\$(grep "^\$1 \$2 " "$T/l2table" || echo "\$1 \$2 none")" "\$2"; }
sweep
X
NG() { : > "$T/acts"; GT_BE98_RTL8372="$R" PATH="$T/bin:$PATH" sh "$T/ng.run"; }
latched() { grep '^jack' "$T/run/gt-be98-lan.tripped" 2>/dev/null | tr '\n' ' '; }
clear_latch() { rm -f "$T/run/gt-be98-lan.tripped" "$T/run/gt-be98-lan.tripped.src" "$T/lookups"; echo 0x0 > "$R/jack_block"; }
clear_latch; printf '02:00:00:00:0a:02 921 port=6\n02:00:00:00:0a:03 921 port=5\n02:00:00:00:0a:04 921 port=3\n' > "$T/l2table"
counters 0 "02:00:00:00:0a:02" > "$T/counters"; NG
check "a BPDU source learned on port 6 (a jack of VLAN 921): jack 6 only latched, jack_block 64 (bit 6), one lookup '<mac> 921', rnr1.921 kept" \
	"jack6 |64|02:00:00:00:0a:02 921|0" "$(latched)|$(cat "$R/jack_block")|$(tr '\n' ' ' < "$T/lookups" | sed 's/ $//')|$(grep -c 'rnr1.921 nomaster' "$T/acts")"
check "... one log line naming the jack and how it was attributed" "1" \
	"$(grep -c 'log BPDU guard: a BPDU from 02:00:00:00:0a:02 entered on rnr1.921 .*jack(s) 6 latched off (attributed: the switch learned the source on port 6' "$T/acts")"
NG
check "the same source again: no second lookup, no second log, jack_block in step: not rewritten" "1 0 64" \
	"$(grep -c . "$T/lookups") $(grep -c '^log BPDU' "$T/acts") $(cat "$R/jack_block")"
echo 0x0 > "$R/jack_block"; NG
check "jack_block reset (a module reload): written again from the latch" "64 1" "$(cat "$R/jack_block") $(grep -c 'jack_block was 0x0, written 64' "$T/acts")"
clear_latch; counters 0 "02:00:00:00:0a:09" > "$T/counters"; NG
check "control: a source the switch has not learned: EVERY jack of VLAN 921 (4, 6; not 5 of VLAN 30), jack_block 80" "jack4 jack6 |80" "$(latched)|$(cat "$R/jack_block")"
check "... logged as not attributed" "1" "$(grep -c 'jack(s) 4 6 latched off (not attributed: the source is not in the switch.s L2 table on VLAN 921, so every jack of VLAN 921' "$T/acts")"
clear_latch; counters 0 "02:00:00:00:0a:03" > "$T/counters"; NG
check "a source learned on port 5 (a jack of VLAN 30): every jack of VLAN 921" "jack4 jack6 |80" "$(latched)|$(cat "$R/jack_block")"
clear_latch; counters 0 "02:00:00:00:0a:04, 02:00:00:00:0a:02" > "$T/counters"; NG
check "two sources, one on port 3 (the uplink) and one on jack 6: every jack of VLAN 921, two lookups, two log lines" "jack4 jack6 |80|2 2" \
	"$(latched)|$(cat "$R/jack_block")|$(grep -c . "$T/lookups") $(grep -c '^log BPDU guard: a BPDU from' "$T/acts")"
clear_latch; rm -f "$T/l2table"; counters 0 "02:00:00:00:0a:02" > "$T/counters"; NG
check "the lookup fails (the driver answers nothing): every jack of VLAN 921" "jack4 jack6 |80" "$(latched)|$(cat "$R/jack_block")"
# the real l2_lookup on a plain file (no driver behind it: it reads back what
# it wrote): an answer it cannot parse, so every jack of the VLAN
clear_latch; counters 0 "02:00:00:00:0a:02" > "$T/counters"
: > "$T/acts"; GT_BE98_RTL8372="$R" PATH="$T/bin:$PATH" sh "$G" --sweep
check "the real l2_lookup against a plain file: it wrote '<mac> <vid>', the answer is refused: every jack of VLAN 921" "02:00:00:00:0a:02 921|jack4 jack6 |80" \
	"$(cat "$R/l2_lookup")|$(latched)|$(cat "$R/jack_block")"
clear_latch; rm -f "$T/run/gt-be98-lan.applied"
# a conf saved by an older image: the LAN_PORT_* keys absent = no jack (rnr1 in a brwifi bridge detached), the rest untouched
rm -f "$T/run/gt-be98-lan.applied" "$T/run/gt-be98-lan.tripped"
grep -v '^LAN_PORT_' "$here/../src/conf.d/gt-be98-lan" > "$T/lan.conf"
rm -rf "$S"; mkdir -p "$S/lo"; port brwifi1 rnr0.921 0 0; port brwifi1 rnr1 0 0; port brwifi1 bcawl0 0 0
: > "$T/acts"; PATH="$T/bin:$PATH" sh "$G" --sweep
check "older-image conf (LAN_PORT_* absent): rnr1 in brwifi1 detached, its trunk VLAN and the BSS kept, no nft" \
	"ip link set rnr1 nomaster|0" "$(grep '^ip ' "$T/acts" | tr '\n' '|')$(grep -c '^nft ' "$T/acts")"
rm -rf "$T/run/gt-be98-l2" "$T/run/gt-be98-lan.applied" "$T/run/gt-be98-lan.tripped" "$T/counters"
printf 'LAN_PORTS="rnr1"\nLAN_BRIDGE=br-lan\n' > "$T/lan.conf"

# rule 6 (gateway networks, sweep level): the list's mode=gateway VLAN 921
# loses its trunk VLAN rnr0.921 even listed in WIFI_VLANS; the bridge's
# wired member rnr1.921 (gt-be98-l2 "trunk -", uplink rnr0) and BSS stay
printf 'WIFI_TRUNK="rnr0"\nWIFI_VLANS="brwifi1:921"\n' > "$T/l2.conf"
mkdir -p "$T/run/gt-be98-l2"; printf 'trunk -\nuplink rnr0\nvid 921\nmade_bridge 1\nmade_vlan 0\nuser wifi\nuser lan\nwired lan rnr1.921 1\n' > "$T/run/gt-be98-l2/brwifi1"
printf 'network=4 name=Lab vlan=921 subnet=192.168.40.1/24 mode=gateway isolate=0 mgmt=1\n' > "$T/networks.conf"
gsweep() { rm -rf "$S"; mkdir -p "$S/lo"; port brwifi1 rnr0.921 0 0; port brwifi1 rnr1.921 0 0; port brwifi1 bcawl0 0 0
	: > "$T/acts"; GT_BE98_NETWORKS="$T/networks.conf" PATH="$T/bin:$PATH" $SH "$G" --sweep; grep '^ip ' "$T/acts" | tr '\n' '|'; }
check "rule 6: a gateway network's rnr0.921 detached (even listed), rnr1.921 and the BSS kept" "ip link set rnr0.921 nomaster|" "$(gsweep)"
check "... logged with its reason" yes "$(grep -q 'log detached rnr0.921 from bridge brwifi1 (VLAN 921 is a gateway network' "$T/acts" && echo yes || echo no)"
printf 'trunk rnr0\nuplink rnr0\nvid 921\nmade_bridge 1\nmade_vlan 0\nuser wifi\nuser lan\nwired lan rnr1.921 1\n' > "$T/run/gt-be98-l2/brwifi1"
printf 'network=4 name=Lab vlan=921 subnet=192.168.40.1/24\n' > "$T/networks.conf"
check "control: the same VLAN without mode=gateway (D-GW1): nothing detached" "" "$(gsweep)"
rm -rf "$T/run/gt-be98-l2" "$T/networks.conf"
# the verdict tables (gt-be98-netguard --selftest)
if $SH "$G" --selftest > "$T/st.out" 2>&1; then check "--selftest: $(tail -n1 "$T/st.out")" 0 0
else check "--selftest" 0 1; grep FAIL "$T/st.out"; fi

if [ $fail = 0 ]; then echo "ALL OK ($n checks)"; else echo "FAILED"; fi
exit $fail

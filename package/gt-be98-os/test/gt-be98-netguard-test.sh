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
if [ $fail = 0 ]; then echo "ALL OK ($n checks)"; else echo "FAILED"; fi
exit $fail

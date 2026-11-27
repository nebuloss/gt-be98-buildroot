#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# Mutants of the AP MLD rules of init.d/gt-be98-wifi (MLD-RADIO-RESTART, the
# MAP-first order, the netdev ADD key on a shared wiphy, mld0 with its radio
# mask, the monitor's radios): each mutant removes one rule and
# test/gt-be98-wifi-service-test.sh must go RED. No device, no root.
#   sh test/gt-be98-wifi-mld-mutants.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
svc=$here/../src/init.d/gt-be98-wifi
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
killed=0 survived=0
mutant() {	# name sed-expression
	sed "$2" "$svc" > "$T/svc"
	if cmp -s "$svc" "$T/svc"; then echo "BAD  $1: the expression changed nothing"; survived=$((survived + 1)); return; fi
	if SVC="$T/svc" sh "$here/gt-be98-wifi-service-test.sh" > "$T/log" 2>&1; then
		echo "SURVIVED $1"; survived=$((survived + 1))
	else
		echo "killed   $1 ($(grep -c '^FAIL' "$T/log") FAIL)"; killed=$((killed + 1))
	fi
}
mutant "a link radio restarted alone" 's/	if mld_radio "$d" \&\& \[ "${MLD_FULL_DONE:-0}" != 1 \] \&\& \[ -f "$STATE\/mld" \]; then/	if false; then/'
mutant "no full restart on an MLD change" 's/			hap_daemon_stop\n			MLD_FULL_DONE=1//; /the AP MLD or one of its link radios changed: full hostapd restart/{n;s/.*hap_daemon_stop.*/			:/}'
mutant "the plan order (no MAP first)" 's/	for d in $(mld_order "$want"); do$/	for d in $want; do/'
mutant "the phy as the ADD key on a shared wiphy" 's/	if \[ "$n" -gt 1 \]; then echo "$d"; else echo "$phy"; fi/	echo "$phy"/'
mutant "mld0 without its radio mask" 's/	iw phy "$phy" interface add "$ifn" type __ap addr "$a" radios "$mask"/	iw phy "$phy" interface add "$ifn" type __ap addr "$a"/'
mutant "no wait for the old hostapd" 's|--retry "TERM/${HOSTAPD_STOP_WAIT:-30}/KILL/5"|--retry TERM/5/KILL/2|'
mutant "a monitor without radios" 's/		if \[ -n "$r" \]; then iw phy "$phy" interface add "$m" type monitor radios/		if false; then iw phy "$phy" interface add "$m" type monitor radios/'
mutant "mld0 kept when the MLD goes away" 's/	if \[ -e "$SYSNET\/$ifn" \]; then iw dev "$ifn" del 2>\/dev\/null || ewarn "MLD: $ifn not deleted"; fi/	:/'
mutant "no member netdev up (MLO-PROD2 20)" 's/^	members_up$/	:/'
mutant "a member up only when configured" 's/	for d in bcawl2 bcawl1 bcawl3; do$/	for d in; do/'
echo "gt-be98-wifi MLD mutants: $killed killed, $survived survived"
[ $survived = 0 ]

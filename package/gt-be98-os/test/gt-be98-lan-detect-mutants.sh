#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# Mutants of `gt-be98-lan detect` (sbin/gt-be98-lan): each removes one guarantee; the unit test
# (test/gt-be98-lan-detect-test.sh) must fail on every one, and pass on the unmutated script (control).
set -u
here=$(cd "$(dirname "$0")" && pwd)
SRC=$here/../src/sbin/gt-be98-lan
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
killed=0 survived=0
sh "$here/gt-be98-lan-detect-test.sh" "$SRC" > "$T/ctl" 2>&1 && echo "ok   control: the unmutated script passes" || { echo "FAIL control"; tail -5 "$T/ctl"; exit 1; }
mut() {	# name old new
	python3 -I - "$SRC" "$T/m" "$2" "$3" <<'PY' || { echo "BAD  $1: anchor not found once"; survived=$((survived + 1)); return; }
import sys
s = open(sys.argv[1]).read(); o, n = sys.argv[3], sys.argv[4]
if s.count(o) != 1: sys.exit(1)
open(sys.argv[2], "w").write(s.replace(o, n))
PY
	if sh "$here/gt-be98-lan-detect-test.sh" "$T/m" > "$T/out" 2>&1; then echo "FAIL survived: $1"; survived=$((survived + 1))
	else echo "ok   killed: $1 ($(grep -c '^FAIL' "$T/out") checks)"; killed=$((killed + 1)); fi
}
mut "bare rnr1 in LAN_PORTS allowed" '[ "$p" = rnr1 ] && fail_json' '[ "$p" = rnr1x ] && fail_json'
mut "an unknown rnr1 VLAN device allowed" 'grep -qx "$v" ||' 'true ||'
mut "the explicit stop skipped" '		sys_write "$RTL/jack_detect" stop || err=' '		true || err='
mut "the stop on a signal skipped" '	[ -n "$DETECT_ON" ] && sys_write "$RTL/jack_detect" stop' '	:'
mut "a refused restore reported as done" '		case "$st" in *state=idle*) ;; *) err=${err:-"the switch is not idle after the detect: $st"} ;; esac' '		err='
mut "the jack set VIDs reported (not skipped)" '		if (vid in skipped) next' '		if (0) next'
mut "promiscuous capture" '"$TCPDUMP" -l -p -n' '"$TCPDUMP" -l -n'
mut "the lock not taken" '	lock_take || fail_json' '	true || fail_json'
mut "the lock not released" '	[ -n "$LOCK_HELD" ] && rm -rf "$RUN_DIR/detect.lock"' '	:'
mut "the DHCP router ignored" 'base = (drouter != "" ? drouter : dyour)' 'base = dyour'
mut "rnr1 as a live bridge port allowed" '		[ -e "$SYS_NET/rnr1/master" ] &&' '		[ -e "$SYS_NET/rnr1/masterx" ] &&'
mut "the rnr1 device reader blind" '$i ~ /@rnr1:?$/' '$i ~ /@rnr9:?$/'
mut "seconds unbounded" '[ "$secs" -le $SECS_MAX ]' '[ "$secs" -le 9999 ]'
mut "a jack capture takes every frame" '		filter=vlan' '		filter='
echo "gt-be98-lan detect mutants: $killed killed, $survived survived"
[ $survived = 0 ]

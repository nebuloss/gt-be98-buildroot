#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# hwsim test of board/gt-be98-mainline/patches/hostapd/0002-mld-failed-add-keeps-the-process.patch
# (a failed AP MLD ADD must not kill a -g hostapd and every interface it runs). On a Linux BUILD host with
# mac80211_hwsim, as root; touches no real radio and no network (hwsim radios are virtual):
#   sudo sh test/hostapd-mld-hwsim-test.sh HOSTAPD_SRC WORKDIR
# HOSTAPD_SRC: the OS's hostapd-2.12 tree (<buildroot output>/build/hostapd-2.12) with or without 0002: it is
# copied twice to WORKDIR (scratch, delete it afterwards), built host-native once WITHOUT 0002 ("before") and once
# WITH it ("after"; needs libnl-3/libnl-genl-3 and OpenSSL headers on the host), and both builds run:
#   A  mac80211_hwsim mlo=0: a plain AP runs, then ADD of an AP MLD on the same wiphy (driver without MLO)
#   B  mac80211_hwsim mlo=1 channels=1: a plain AP on ch 1, an MLD's first link on ch 1, then its non-first link on
#      ch 6 (one channel context: mac80211 refuses that link at start)
# Expected: "before" DIES in A and B (the 2.12 crash); "after" answers FAIL to the bad ADD and keeps the process
# and the plain AP (ENABLED). Exit 0 only when all four cells are as expected.
set -u
src=${1:?HOSTAPD_SRC}; w=${2:?WORKDIR}
here=$(cd "$(dirname "$0")" && pwd)
patch=$here/../../../board/gt-be98-mainline/patches/hostapd/0002-mld-failed-add-keeps-the-process.patch
[ "$(id -u)" = 0 ] || { echo "needs root (modprobe mac80211_hwsim)"; exit 2; }
[ -f "$src/hostapd/main.c" ] && [ -f "$patch" ] || { echo "no hostapd tree at $src or no patch at $patch"; exit 2; }
modinfo mac80211_hwsim > /dev/null 2>&1 || /sbin/modinfo mac80211_hwsim > /dev/null 2>&1 || { echo "no mac80211_hwsim"; exit 2; }
PATH=$PATH:/sbin:/usr/sbin
rm -rf "$w"; mkdir -p "$w/lib"
[ -e /usr/lib/x86_64-linux-gnu/libnl-genl-3.so ] || ln -sf /usr/lib/x86_64-linux-gnu/libnl-genl-3.so.200 "$w/lib/libnl-genl-3.so"
build() {	# build NAME PATCHED(0|1)
	cp -a "$src" "$w/$1"
	cd "$w/$1"
	find . \( -name '*.o' -o -name '*.d' \) -exec rm -f {} +
	rm -rf build
	if grep -q 'Not on the list: never added' src/ap/hostapd.c; then
		[ "$2" = 1 ] || patch -s -R -p1 < "$patch" || return 1
	else
		[ "$2" = 0 ] || patch -s -p1 < "$patch" || return 1
	fi
	cd hostapd
	printf '%s\n' CONFIG_DRIVER_NL80211=y CONFIG_LIBNL32=y CONFIG_IEEE80211N=y CONFIG_IEEE80211AC=y \
		CONFIG_IEEE80211AX=y CONFIG_IEEE80211BE=y CONFIG_SAE=y CONFIG_CTRL_IFACE=y CONFIG_DEBUG_FILE=y \
		CONFIG_NO_RANDOM_POOL=y > .config
	CFLAGS="-g -O1 -I/usr/include/libnl3 -MMD" LDFLAGS="-L$w/lib" make -s -j"$(nproc)" hostapd hostapd_cli > ../make.log 2>&1 ||
		{ tail -5 ../make.log; return 1; }
	cd "$here"
}
conf() {	# conf FILE IFACE SSID CHANNEL [mld]
	{ printf 'interface=%s\ndriver=nl80211\nctrl_interface=%s/ctrl\nssid=%s\nhw_mode=g\nchannel=%s\n' "$2" "$D" "$3" "$4"
	  printf 'ieee80211n=1\nieee80211ax=1\nieee80211be=1\nwpa=2\nwpa_key_mgmt=SAE\nrsn_pairwise=CCMP\nieee80211w=2\nsae_password=hwsim-pass-1\nsae_pwe=1\n'
	  [ -n "${5:-}" ] && echo mld_ap=1; } > "$1"
}
run() {	# run NAME SCENARIO -> "DIED|ALIVE <bad ADD reply> <plain state>"
	H=$w/$1/hostapd/hostapd; HC=$w/$1/hostapd/hostapd_cli; D=/run/hostapd-mld-hwsim; rm -rf $D; mkdir -p $D
	modprobe -r mac80211_hwsim 2>/dev/null
	if [ "$2" = A ]; then modprobe mac80211_hwsim radios=1 mlo=0; else modprobe mac80211_hwsim radios=1 mlo=1 channels=1; fi || { echo "MODPROBE-FAILED"; return; }
	sleep 1
	W=$(ls /sys/class/ieee80211/*/device/net 2>/dev/null | grep -m1 '^wlan')
	P=$(basename "$(readlink -f /sys/class/net/$W/phy80211)")
	iw phy "$P" interface add hwmld0 type __ap
	conf $D/plain.conf "$W" hw-plain 1
	conf $D/l0.conf hwmld0 hw-mld 1 mld; conf $D/l1.conf hwmld0 hw-mld 6 mld
	$H -B -P $D/pid -t -f $D/hostapd.log -g $D/global
	sleep 1
	$HC -p $D -i global raw ADD bss_config=$P:$D/plain.conf > /dev/null; sleep 2
	if [ "$2" = A ]; then r=$($HC -p $D -i global raw ADD bss_config=hwmld0:$D/l0.conf 2>&1 | tail -n1)
	else $HC -p $D -i global raw ADD bss_config=$P:$D/l0.conf > /dev/null; sleep 2
	     r=$($HC -p $D -i global raw ADD bss_config=$P:$D/l1.conf 2>&1 | tail -n1); fi
	sleep 3
	p=$(cat $D/pid 2>/dev/null)
	if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then a=ALIVE; else a=DIED; fi
	s=$($HC -p $D/ctrl -i "$W" status 2>/dev/null | sed -n 's/^state=//p')
	[ -n "$p" ] && kill "$p" 2>/dev/null; sleep 1
	modprobe -r mac80211_hwsim
	case "$r" in *timed\ out*) r=TIMEOUT ;; esac
	echo "$a ${r:-none} ${s:--}"
}
build before 0 || { echo "build (before) failed"; exit 1; }
build after 1 || { echo "build (after) failed"; exit 1; }
fail=0
for c in "before A DIED" "before B DIED" "after A ALIVE FAIL ENABLED" "after B ALIVE FAIL ENABLED"; do
	set -- $c; got=$(run "$1" "$2")
	case "$3" in
	DIED) want="DIED"; case "$got" in DIED*) ok=1 ;; *) ok=0 ;; esac ;;
	*) want="$3 $4 $5"; [ "$got" = "$want" ] && ok=1 || ok=0 ;;
	esac
	if [ $ok = 1 ]; then echo "ok   $1 $2: $got"; else echo "FAIL $1 $2: want [$want] got [$got]"; fail=1; fi
done
if [ $fail = 0 ]; then echo "ALL OK (4 checks)"; else echo FAILED; fi
exit $fail

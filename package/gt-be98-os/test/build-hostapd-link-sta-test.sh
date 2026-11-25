#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# Build and run hostapd-link-sta-test (test/hostapd-link-sta-test.c) on the BUILD host from a hostapd tree that
# carries the board patches (0001-0006), as build-hostapd-dfs-bg-test.sh does (driver "none", no libnl, the
# target's EHT config WITHOUT CONFIG_TESTING_OPTIONS).
#   sh test/build-hostapd-link-sta-test.sh HOSTAPD_SRC WORKDIR
#   sh test/build-hostapd-link-sta-test.sh --selftest HOSTAPD_SRC WORKDIR
# --selftest: control 1 = the tree WITHOUT 0006 (reversed: it does not build the test, hostapd_link_remove is a
# testing option there); control 2 = 0006 without its sta_info.c half (must be RED at S1 by behaviour); the given
# tree must be GREEN. Exit 0 GREEN, 1 RED.
set -eu
st=0; [ "${1:-}" = --selftest ] && { st=1; shift; }
src=${1:?HOSTAPD_SRC}; w=${2:?WORKDIR}
here=$(cd "$(dirname "$0")" && pwd)
p6=$here/../../../board/gt-be98-mainline/patches/hostapd/0006-mld-link-removal-keeps-the-station.patch
mkdir -p "$w"
build() {	# build <tree> <out>
	rm -rf "$w/b"; cp -a "$1" "$w/b"
	( cd "$w/b/hostapd"
	  make -s clean >/dev/null 2>&1 || true
	  find .. \( -name '*.o' -o -name '*.d' \) -exec rm -f {} +
	  printf '%s\n' CONFIG_DRIVER_NONE=y CONFIG_IEEE80211N=y CONFIG_IEEE80211AC=y CONFIG_IEEE80211AX=y \
		CONFIG_IEEE80211BE=y CONFIG_SAE=y CONFIG_CTRL_IFACE=y CONFIG_NO_RANDOM_POOL=y > .config
	  cp "$here/hostapd-link-sta-test.c" linksta.c
	  cat > linksta.mk <<'MK'
LINKSTA := linksta.o
_OBJS_VAR := LINKSTA
include ../src/objs.mk
LS_OBJS = $(filter-out %/hostapd/main.o %/src/drivers/drivers.o,$(OBJS)) $(LINKSTA)
hostapd-link-sta-test: $(LS_OBJS)
	$(Q)$(LDO) $(LDFLAGS) -Wl,--wrap=wpa_msg -Wl,--wrap=ieee802_11_set_beacon -o $@ $(LS_OBJS) $(LIBS)
MK
	  make -s -j"$(nproc)" -f Makefile -f linksta.mk hostapd-link-sta-test CC="${HOSTCC:-gcc}" >/dev/null ) || return 1
	cp "$w/b/hostapd/hostapd-link-sta-test" "$2"
}
grep -q 'gt-be98 0006' "$src/src/ap/sta_info.c" || { echo "$src: no 0006 in this tree" >&2; exit 1; }
build "$src" "$w/t-given" || { echo "RED (the given tree does not build the test)"; exit 1; }
echo "=== the given tree"
rc=0; "$w/t-given" || rc=$?
[ "$st" = 1 ] || exit $rc
[ $rc = 0 ] || { echo "RED (selftest: the given tree is RED)"; exit 1; }
echo "=== control: the same tree without 0006 (must be RED)"
rm -rf "$w/cb"; cp -a "$src" "$w/cb"
(cd "$w/cb" && patch -p1 -R -s < "$p6")
crc=0
if build "$w/cb" "$w/t-ctl"; then "$w/t-ctl" || crc=$?; else echo "(the control does not link: hostapd_link_remove is a testing option there)"; crc=1; fi
[ $crc != 0 ] || { echo "RED (selftest: control 1 is GREEN)"; exit 1; }
# control 2: 0006 without its station half (src/ap/sta_info.c as 2.12 + 0001-0005): S1 must be RED by behaviour
echo "=== control 2: 0006 without its src/ap/sta_info.c half (must be RED at S1)"
rm -rf "$w/c2"; cp -a "$src" "$w/c2"; cp "$w/cb/src/ap/sta_info.c" "$w/c2/src/ap/sta_info.c"
c2=0; build "$w/c2" "$w/t-c2" && { "$w/t-c2" || c2=$?; } || c2=1
[ $c2 != 0 ] && { echo "GREEN (selftest: given GREEN, both controls RED)"; exit 0; }
echo "RED (selftest: control 2 is GREEN)"; exit 1

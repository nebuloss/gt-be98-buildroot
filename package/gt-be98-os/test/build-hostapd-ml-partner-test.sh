#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# Build and run hostapd-ml-partner-test (test/hostapd-ml-partner-test.c) on the BUILD host from a hostapd tree that
# carries the board patches (0001-0007), as build-hostapd-link-sta-test.sh does (driver "none", no libnl, the
# target's EHT config WITHOUT CONFIG_TESTING_OPTIONS).
#   sh test/build-hostapd-ml-partner-test.sh HOSTAPD_SRC WORKDIR
#   sh test/build-hostapd-ml-partner-test.sh --selftest HOSTAPD_SRC WORKDIR
# --selftest: control 1 = the tree WITHOUT 0007 (reversed; must be RED by behaviour: S1b, S2a, S3a, S4b); control 2 = 0007
# without its src/ap/sta_info.c half (must be RED at S3a: the AP-initiated deauth misses link 1); control 3 = 0007
# without its src/ap/ieee802_11.c half (must be RED at S4b: the rejoin right after a deauthentication is refused); the
# given tree must be GREEN. Exit 0 GREEN, 1 RED.
set -eu
st=0; [ "${1:-}" = --selftest ] && { st=1; shift; }
src=${1:?HOSTAPD_SRC}; w=${2:?WORKDIR}
here=$(cd "$(dirname "$0")" && pwd)
p7=$here/../../../board/gt-be98-mainline/patches/hostapd/0007-mld-link-at-any-bss-index.patch
mkdir -p "$w"
build() {	# build <tree> <out>
	rm -rf "$w/b"; cp -a "$1" "$w/b"
	( cd "$w/b/hostapd"
	  make -s clean >/dev/null 2>&1 || true
	  find .. \( -name '*.o' -o -name '*.d' \) -exec rm -f {} +
	  printf '%s\n' CONFIG_DRIVER_NONE=y CONFIG_IEEE80211N=y CONFIG_IEEE80211AC=y CONFIG_IEEE80211AX=y \
		CONFIG_IEEE80211BE=y CONFIG_SAE=y CONFIG_CTRL_IFACE=y CONFIG_NO_RANDOM_POOL=y > .config
	  cp "$here/hostapd-ml-partner-test.c" mlpartner.c
	  cat > mlpartner.mk <<'MK'
MLPARTNER := mlpartner.o
_OBJS_VAR := MLPARTNER
include ../src/objs.mk
MP_OBJS = $(filter-out %/hostapd/main.o %/src/drivers/drivers.o,$(OBJS)) $(MLPARTNER)
hostapd-ml-partner-test: $(MP_OBJS)
	$(Q)$(LDO) $(LDFLAGS) -Wl,--wrap=wpa_msg -Wl,--wrap=wpa_printf -Wl,--wrap=ieee802_11_set_beacon -o $@ $(MP_OBJS) $(LIBS)
MK
	  make -s -j"$(nproc)" -f Makefile -f mlpartner.mk hostapd-ml-partner-test CC="${HOSTCC:-gcc}" >/dev/null ) || return 1
	cp "$w/b/hostapd/hostapd-ml-partner-test" "$2"
}
grep -q 'gt-be98 0007' "$src/src/ap/hostapd.c" || { echo "$src: no 0007 in this tree" >&2; exit 1; }
build "$src" "$w/t-given" || { echo "RED (the given tree does not build the test)"; exit 1; }
echo "=== the given tree"
rc=0; "$w/t-given" || rc=$?
[ "$st" = 1 ] || exit $rc
[ $rc = 0 ] || { echo "RED (selftest: the given tree is RED)"; exit 1; }
echo "=== control 1: the same tree without 0007 (must be RED)"
rm -rf "$w/cb"; cp -a "$src" "$w/cb"
(cd "$w/cb" && patch -p1 -R -s < "$p7")
c1=0; build "$w/cb" "$w/t-c1" && { "$w/t-c1" || c1=$?; } || c1=1
[ $c1 != 0 ] || { echo "RED (selftest: control 1 is GREEN)"; exit 1; }
echo "=== control 2: 0007 without its src/ap/sta_info.c half (must be RED at S3a)"
rm -rf "$w/c2"; cp -a "$src" "$w/c2"; cp "$w/cb/src/ap/sta_info.c" "$w/c2/src/ap/sta_info.c"
c2=0; build "$w/c2" "$w/t-c2" && { "$w/t-c2" > "$w/c2.out" 2>&1 || c2=$?; } || c2=1
cat "$w/c2.out" 2>/dev/null | grep -E '^(RED|ok)' || true
[ $c2 != 0 ] && grep -q '^RED  S3a' "$w/c2.out" || { echo "RED (selftest: control 2 is not RED at S3a)"; exit 1; }
echo "=== control 3: 0007 without its src/ap/ieee802_11.c half (must be RED at S4b)"
rm -rf "$w/c3"; cp -a "$src" "$w/c3"; cp "$w/cb/src/ap/ieee802_11.c" "$w/c3/src/ap/ieee802_11.c"
c3=0; build "$w/c3" "$w/t-c3" && { "$w/t-c3" > "$w/c3.out" 2>&1 || c3=$?; } || c3=1
grep -E '^(RED|ok)' "$w/c3.out" 2>/dev/null || true
if [ $c3 != 0 ] && grep -q '^RED  S4b' "$w/c3.out"; then echo "GREEN (selftest: given GREEN, all three controls RED)"; exit 0; fi
echo "RED (selftest: control 3 is not RED at S4b)"; exit 1

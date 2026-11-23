#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# Build and run hostapd-dfs-bg-test (test/hostapd-dfs-bg-test.c) on the BUILD
# host from a hostapd tree that carries the board patches (0001-0005), the
# same way build-hostapd-confcheck.sh builds its parser check (the target's
# .config, no libnl, driver "none"), with the driver calls wrapped.
#   sh test/build-hostapd-dfs-bg-test.sh HOSTAPD_SRC WORKDIR
#   sh test/build-hostapd-dfs-bg-test.sh --selftest HOSTAPD_SRC WORKDIR
# --selftest (env CONTROL_PATCHES = earlier 0005s, e.g. r1 and r2): also builds
# the tree with each in place of the given 0005: the test must be RED on every
# one and GREEN on the given tree. WORKDIR is scratch.
# Exit 0 GREEN (selftest: GREEN + every control RED), 1 RED.
set -eu
st=0; [ "${1:-}" = --selftest ] && { st=1; shift; }
src=${1:?HOSTAPD_SRC}; w=${2:?WORKDIR}
here=$(cd "$(dirname "$0")" && pwd)
pd=$here/../../../board/gt-be98-mainline/patches/hostapd
conf="$w/zw80.conf"
mkdir -p "$w"
printf 'interface=bcawl1\ndriver=nl80211\nssid=t\ncountry_code=DE\nieee80211d=1\nieee80211h=1\nhw_mode=a\nchannel=100\nvht_oper_centr_freq_seg0_idx=106\nchanlist=100-112 132-136\nenable_background_radar=1\nieee80211n=1\nht_capab=[HT40+]\nieee80211ac=1\nvht_oper_chwidth=1\n' > "$conf"
build() {	# build <tree> <out>
	rm -rf "$w/b"; cp -a "$1" "$w/b"
	( cd "$w/b/hostapd"
	  make -s clean >/dev/null 2>&1 || true
	  find .. \( -name '*.o' -o -name '*.d' \) -exec rm -f {} +
	  if [ -f .config ]; then cp .config .config.target; else cp defconfig .config.target; fi
	  sed -e 's/^CONFIG_DRIVER_NL80211=y/# CONFIG_DRIVER_NL80211 is not set/' \
	      -e 's/^CONFIG_LIBNL32=y/# CONFIG_LIBNL32 is not set/' \
	      -e 's/^CONFIG_VLAN_NETLINK=y/# CONFIG_VLAN_NETLINK is not set/' \
	      -e '/^CONFIG_DRIVER_NONE/d' .config.target > .config
	  echo CONFIG_DRIVER_NONE=y >> .config
	  cp "$here/hostapd-dfs-bg-test.c" dfsbg.c
	  cat > dfsbg.mk <<'MK'
DFSBG := dfsbg.o
_OBJS_VAR := DFSBG
include ../src/objs.mk
DB_OBJS = $(filter-out %/hostapd/main.o %/src/drivers/drivers.o,$(OBJS)) $(DFSBG)
hostapd-dfs-bg-test: $(DB_OBJS)
	$(Q)$(LDO) $(LDFLAGS) -Wl,--wrap=hostapd_start_dfs_cac -Wl,--wrap=hostapd_switch_channel -Wl,--wrap=hostapd_disable_iface -Wl,--wrap=hostapd_enable_iface -Wl,--wrap=eloop_register_timeout -Wl,--wrap=eloop_cancel_timeout -o $@ $(DB_OBJS) $(LIBS)
MK
	  make -s -j"$(nproc)" -f Makefile -f dfsbg.mk hostapd-dfs-bg-test CC="${HOSTCC:-gcc}" >/dev/null )
	cp "$w/b/hostapd/hostapd-dfs-bg-test" "$2"
}
grep -q 'dfs_background_pick' "$src/src/ap/dfs.c" || { echo "$src: no 0005 in this tree" >&2; exit 1; }
build "$src" "$w/t-given"
echo "=== the given tree"
rc=0; "$w/t-given" "$conf" || rc=$?
[ "$st" = 1 ] || exit $rc
[ $rc = 0 ] || { echo "RED (selftest: the given tree is RED)"; exit 1; }
fail=0
# the controls: the same tree with an EARLIER 0005 in place of the given one, each must be RED —
# CONTROL_PATCHES="<0005 r1> <0005 r2>" (git show f2467c5: / 45f7c74:<the 0005 path>): r1 = the
# q343 hostapd (132/80 over the disabled 144), r2 = the q352 hostapd (no retry of a refused way back)
[ -n "${CONTROL_PATCHES:-}" ] || { echo "RED (selftest needs CONTROL_PATCHES)"; exit 1; }
k=0
for cp in $CONTROL_PATCHES; do
	k=$((k + 1))
	echo "=== control $k: $(basename "$cp") in place of the given 0005 (must be RED)"
	rm -rf "$w/cb"; cp -a "$src" "$w/cb"
	(cd "$w/cb" && patch -p1 -R -s < "$pd/0005-dfs-background-chain-narrower-standby-and-way-back.patch" && patch -p1 -s < "$cp")
	build "$w/cb" "$w/t-cb$k"
	if "$w/t-cb$k" "$conf" > "$w/cb$k.out" 2>&1; then echo "  BLIND: GREEN"; fail=1
	else echo "  ok: RED ($(grep -c '^RED ' "$w/cb$k.out") checks; first: $(grep '^RED ' "$w/cb$k.out" | head -1 | cut -c1-140))"; fi
done
[ $fail = 0 ] && { echo "GREEN (selftest)"; exit 0; }
echo "RED (selftest)"; exit 1

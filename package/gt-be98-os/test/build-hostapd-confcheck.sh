#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# Build hostapd-confcheck (test/hostapd-confcheck.c) on the BUILD host from the
# OS's own hostapd source tree, with the target's .config but no driver
# backend (no libnl needed): hostapd's config parser and checks, run offline.
#   sh test/build-hostapd-confcheck.sh HOSTAPD_SRC WORKDIR
# HOSTAPD_SRC: e.g. <buildroot output>/build/hostapd-2.12 (its hostapd/.config
# is the target's). Writes WORKDIR/hostapd-confcheck; WORKDIR is scratch
# (a copy of the source, the host objects): delete it afterwards.
set -eu
src=${1:?HOSTAPD_SRC}; w=${2:?WORKDIR}
here=$(cd "$(dirname "$0")" && pwd)
[ -f "$src/hostapd/config_file.c" ] || { echo "$src: not a hostapd tree" >&2; exit 1; }
mkdir -p "$w"
rm -rf "$w/src"
cp -a "$src" "$w/src"
cd "$w/src/hostapd"
make -s clean >/dev/null 2>&1 || true
find .. \( -name '*.o' -o -name '*.d' \) -exec rm -f {} +
# the target's options, minus what needs libnl (the nl80211 backend, the
# netlink VLAN code: no parser key depends on them), plus driver "none"
if [ -f .config ]; then cp .config .config.target; else cp defconfig .config.target; fi
sed -e 's/^CONFIG_DRIVER_NL80211=y/# CONFIG_DRIVER_NL80211 is not set/' \
    -e 's/^CONFIG_LIBNL32=y/# CONFIG_LIBNL32 is not set/' \
    -e 's/^CONFIG_VLAN_NETLINK=y/# CONFIG_VLAN_NETLINK is not set/' \
    -e '/^CONFIG_DRIVER_NONE/d' .config.target > .config
echo CONFIG_DRIVER_NONE=y >> .config
cp "$here/hostapd-confcheck.c" confcheck.c
cat > confcheck.mk <<'EOF'
# objects live under $(BUILDDIR) (src/build.rules, src/objs.mk)
CCK := confcheck.o
_OBJS_VAR := CCK
include ../src/objs.mk
CC_OBJS = $(filter-out %/hostapd/main.o %/src/drivers/drivers.o,$(OBJS)) $(CCK)
hostapd-confcheck: $(CC_OBJS)
	$(Q)$(LDO) $(LDFLAGS) -o $@ $(CC_OBJS) $(LIBS)
EOF
make -s -j"$(nproc)" -f Makefile -f confcheck.mk hostapd-confcheck CC="${HOSTCC:-gcc}"
cp hostapd-confcheck "$w/hostapd-confcheck"
echo "$w/hostapd-confcheck"

#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# Build wpa_supplicant-confcheck (test/wpa_supplicant-confcheck.c) on the
# BUILD host from the OS's own wpa_supplicant source tree, with the target's
# .config but no driver backend (no libnl, no D-Bus): wpa_supplicant's
# config parser, run offline (gt-be98-wifi-gen-test.sh WPA_CONFCHECK=).
#   sh test/build-wpa-confcheck.sh WPA_SUPPLICANT_SRC WORKDIR
# WPA_SUPPLICANT_SRC: e.g. <buildroot output>/build/wpa_supplicant-2.12 (its
# wpa_supplicant/.config is the target's). Writes WORKDIR/wpa_supplicant-
# confcheck; WORKDIR is scratch (a copy of the source): delete it afterwards.
set -eu
src=${1:?WPA_SUPPLICANT_SRC}; w=${2:?WORKDIR}
here=$(cd "$(dirname "$0")" && pwd)
[ -f "$src/wpa_supplicant/config_file.c" ] || { echo "$src: not a wpa_supplicant tree" >&2; exit 1; }
mkdir -p "$w"
rm -rf "$w/src"
cp -a "$src" "$w/src"
cd "$w/src/wpa_supplicant"
make -s clean >/dev/null 2>&1 || true
find .. \( -name '*.o' -o -name '*.d' \) -exec rm -f {} +
if [ -f .config ]; then cp .config .config.target; else cp defconfig .config.target; fi
# the target's options, minus libnl (nl80211) and D-Bus, plus driver "none";
# our main() (CONFIG_MAIN) instead of wpa_supplicant's
sed -e 's/^CONFIG_DRIVER_NL80211=y/# CONFIG_DRIVER_NL80211 is not set/' \
    -e 's/^CONFIG_LIBNL32=y/# CONFIG_LIBNL32 is not set/' \
    -e '/^CONFIG_CTRL_IFACE_DBUS/d' -e '/^CONFIG_READLINE/d' \
    -e '/^CONFIG_DRIVER_NONE/d' -e '/^CONFIG_MAIN/d' .config.target > .config
echo CONFIG_DRIVER_NONE=y >> .config
echo CONFIG_MAIN=confcheck >> .config
cp "$here/wpa_supplicant-confcheck.c" confcheck.c
make -s -j"$(nproc)" wpa_supplicant CC="${HOSTCC:-gcc}"
cp wpa_supplicant "$w/wpa_supplicant-confcheck"
echo "$w/wpa_supplicant-confcheck"

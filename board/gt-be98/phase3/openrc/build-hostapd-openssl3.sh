#!/usr/bin/env bash
# Reference driver: build the GT-BE98 hostapd DAEMON against openssl-3.6.2
# (gt-be98-br-openssl static staging) instead of the SDK's bundled openssl-1.1.1w.
#
# Standalone equivalent of the gt-be98-hostapd recipe's OPENSSL3 mode
# (BR2_PACKAGE_GT_BE98_HOSTAPD_DAEMON_OPENSSL3 -> glue build-hostapd-daemon.sh with
# OPENSSL3_DEV set). Kept here to reproduce the v32 hostapd outside a full Buildroot
# run. Reuses the proven `make -C router hostapd` flow; libnl is already built in the
# SDK tree. Repoints BOTH openssl-1.1 header paths to openssl-3 (restored on exit so
# the 1.1 fallback tree stays intact): hostapd/Makefile:27-28 (the -I/-L openssl path,
# STATIC libcrypto.a, drop -lssl, +ldl) AND the fs.build/public/include/openssl tree
# from brcm.config:45 (a SECOND 1.1 header tree that wins by include order).
# Paths below are this workspace's; adjust FWROOT/SDK/OSSL3_DEV/OUTDIR elsewhere.
set -uo pipefail

FWROOT=/home/guillaume/be98/gt-be98-firmware
SDK="$FWROOT/vendor/asuswrt-merlin.ng/release/src-rt-5.04behnd.4916"
OSSL3_DEV=/home/guillaume/be98/buildroot/output/build/gt-be98-br-openssl-3.6.2/_brdev/usr/br
PKG_SRC=/home/guillaume/be98/gt-be98-buildroot/package/gt-be98-libshared/src
OUTDIR=/home/guillaume/be98/job-tmp/hostapd-ossl3/out
mkdir -p "$OUTDIR"

HA="$SDK/bcmdrivers/broadcom/net/wl/impl103/main/components/opensource/router_tools/hostapd/hostapd"
MK="$HA/Makefile"

# --- env (decoupled GTBE98_ROOT=firmware-root, SDK=sdk-subdir) ----------------
export GTBE98_ROOT="$FWROOT"
export GTBE98_TC_ROOT="${GTBE98_ROOT}/toolchain/am-toolchains/brcm-arm-hnd"
export SRCBASE="${SDK}/bcmdrivers/broadcom/net/wl/bcm96813/main/src"
export HND_SRC="${SDK}/"
export CFLAGS="$(sed -e "s|@SDK@|${SDK}|g" -e "s|@ROOT@|${GTBE98_ROOT}|g" "${PKG_SRC}/cflags.template.txt")"
export GTBE98=y BUSYBOX_DIR=busybox BCM_WLIMPL=103
export WLAN_ComponentSrcDirs="${SDK}/bcmdrivers/broadcom/net/wl/impl103/main/components/proto/src ${SDK}/bcmdrivers/broadcom/net/wl/impl103/main/components/wlioctl/src ${SDK}/bcmdrivers/broadcom/net/wl/impl103/main/src/shared/bcmwifi/src"
export WLAN_StdIncPathA="-I${SDK}/bcmdrivers/broadcom/net/wl/impl103/main/src/include -I${SDK}/bcmdrivers/broadcom/net/wl/impl103/main/src/shared"

source "${FWROOT}/tools/sanitize-host-env.sh"; gtbe98_sanitize_ld_library_path
source "${FWROOT}/tools/env.sh";              gtbe98_sanitize_ld_library_path

# --- stage openssl-3 where the build's $(TOP)/openssl expects it --------------
# router/openssl is a symlink -> openssl-1.1 (pruned/empty). We do NOT touch it.
# Instead we patch the hostapd Makefile -I/-L to the openssl-3 staging tree and
# static-link libcrypto.a (drop unused -lssl).
cp -a "$MK" "$MK.ossl11.bak"

# brcm.config:45 adds -I$(BCM_FSBUILD_DIR)/public/include which still carries an
# openssl-1.1 header tree (fs.build/public/include/openssl); it wins by include
# order over our -I and would compile crypto_openssl.c against 1.1 (EVP_PKEY_size
# as a function, not the openssl-3 macro -> EVP_PKEY_get_size). Shadow it with the
# openssl-3 headers for the duration of the build (restore on exit).
FSINC="$SDK/targets/96813GW/fs.build/public/include/openssl"
FSINC_BAK="${FSINC}.ossl11.bak"

restore() {
  mv -f "$MK.ossl11.bak" "$MK" 2>/dev/null
  if [ -e "$FSINC_BAK" ]; then rm -rf "$FSINC"; mv -f "$FSINC_BAK" "$FSINC" 2>/dev/null; fi
}
trap restore EXIT

if [ -e "$FSINC" ] && [ ! -L "$FSINC" ]; then
  mv -f "$FSINC" "$FSINC_BAK"
  ln -s "$OSSL3_DEV/include/openssl" "$FSINC"
  echo "=== shadowed fs.build openssl-1.1 headers with openssl-3 ==="
fi

# line 27: CFLAGS += -I$(TOP)/openssl/include   -> openssl-3 headers
# line 28: LDFLAGS += -L$(TOP)/openssl -lcrypto -lm -lssl -lpthread
#          -> STATIC openssl-3 libcrypto.a (no -lssl: 0 libssl symbols imported)
python3 - "$MK" "$OSSL3_DEV" <<'PY'
import sys,re
mk, dev = sys.argv[1], sys.argv[2]
s = open(mk).read()
s = s.replace(
  "CFLAGS += -I$(TOP)/openssl/include",
  f"CFLAGS += -I{dev}/include   # OSSL3-REPOINT")
s = s.replace(
  "LDFLAGS += -L$(TOP)/openssl -lcrypto -lm -lssl -lpthread",
  f"LDFLAGS += -L{dev}/lib -l:libcrypto.a -lm -lpthread -ldl   # OSSL3-STATIC (no -lssl: 0 libssl syms; -ldl for static dso_dlfcn)")
open(mk,"w").write(s)
PY
echo "=== patched hostapd/Makefile openssl lines ==="
grep -nE 'OSSL3' "$MK"

# --- build (openssl/libnl already satisfied; just (re)make hostapd) -----------
cd "$SDK/router"
# force a clean of the hostapd objects so crypto_openssl.o recompiles vs ossl3 headers
env -u LD_LIBRARY_PATH make -C "$HA" clean LD_LIBRARY_PATH= SHELL=/bin/bash >/dev/null 2>&1
env -u LD_LIBRARY_PATH make hostapd LD_LIBRARY_PATH= SHELL=/bin/bash 2>&1 | tail -60
rc=${PIPESTATUS[0]}
echo "=== make hostapd rc=${rc} ==="
[ "$rc" -ne 0 ] && exit "$rc"

cp -a "$HA/hostapd" "$OUTDIR/hostapd.ossl3"
echo "=== built -> $OUTDIR/hostapd.ossl3 ==="
exit 0

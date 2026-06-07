#!/usr/bin/env bash
# gt-be98-hostapd FULL DAEMON from-source build via the merlin SDK build-glue.
#
# Drives the vendor router target `make -C router hostapd`, which sets up the
# full export env (TOP/TOP_PLATFORM/BRCM_CHIP + PKG_CONFIG_PATH for libnl +
# the cross LD) and recurses into the hostapd brcm.config build:
#   DRIVER_BRCM + NL80211 + MLO/MAP/SAE/OWE/HS20/WPS, TLS=openssl, CEVENT.
# Prereqs (libnl, openssl-1.1) build from source in the SDK tree; the daemon
# links our from-source libshared + libnvram, the SDK from-source openssl-1.1
# + libnl, and the pinned closed libceshared.so (KEEP-AS-GRAFT).
#
# Proven result: the resulting binary, stripped, is BYTE-IDENTICAL to the
# shipped device hostapd (sha256 7453000858a8...; same DT_NEEDED) -- a
# reproducible-build match.
#
# Args / env (set by the Buildroot .mk):
#   GTBE98_ROOT   firmware root
#   SDK           .../release/src-rt-5.04behnd.4916
#   PKG_SRC       libshared package src (for cflags.template.txt)
#   OUTDIR        where to drop hostapd (the Buildroot $(@D))
set -uo pipefail
: "${GTBE98_ROOT:?}"; : "${SDK:?}"; : "${PKG_SRC:?}"; : "${OUTDIR:?}"

export GTBE98_ROOT
export GTBE98_TC_ROOT="${GTBE98_ROOT}/toolchain/am-toolchains/brcm-arm-hnd"
export SRCBASE="${SDK}/bcmdrivers/broadcom/net/wl/bcm96813/main/src"
export HND_SRC="${SDK}/"
export CFLAGS="$(sed -e "s|@SDK@|${SDK}|g" -e "s|@ROOT@|${GTBE98_ROOT}|g" "${PKG_SRC}/cflags.template.txt")"
export GTBE98=y BUSYBOX_DIR=busybox BCM_WLIMPL=103
export WLAN_ComponentSrcDirs="${SDK}/bcmdrivers/broadcom/net/wl/impl103/main/components/proto/src ${SDK}/bcmdrivers/broadcom/net/wl/impl103/main/components/wlioctl/src ${SDK}/bcmdrivers/broadcom/net/wl/impl103/main/src/shared/bcmwifi/src"
export WLAN_StdIncPathA="-I${SDK}/bcmdrivers/broadcom/net/wl/impl103/main/src/include -I${SDK}/bcmdrivers/broadcom/net/wl/impl103/main/src/shared"

source "${GTBE98_ROOT}/tools/sanitize-host-env.sh"; gtbe98_sanitize_ld_library_path
source "${GTBE98_ROOT}/tools/env.sh";              gtbe98_sanitize_ld_library_path

HA="${SDK}/bcmdrivers/broadcom/net/wl/impl103/main/components/opensource/router_tools/hostapd/hostapd"
cd "${SDK}/router"
env -u LD_LIBRARY_PATH make hostapd LD_LIBRARY_PATH= SHELL=/bin/bash
rc=$?
echo "=== make -C router hostapd rc=${rc} ==="
[ "${rc}" -ne 0 ] && exit "${rc}"

# NB: $(@D)/hostapd is the synced source subdir; drop the daemon as hostapd.daemon.
cp -a "${HA}/hostapd" "${OUTDIR}/hostapd.daemon"
# Stage the daemon's from-source / pinned runtime deps for rootfs install.
cp -a "${SDK}/router/openssl/libcrypto.so.1.1" "${OUTDIR}/libcrypto.so.1.1"
cp -a "${SDK}/router/openssl/libssl.so.1.1"    "${OUTDIR}/libssl.so.1.1"
cp -a "${SDK}/targets/96813GW/fs/lib/libnl-3.so.200.20.0"      "${OUTDIR}/libnl-3.so.200.20.0"
cp -a "${SDK}/targets/96813GW/fs/lib/libnl-genl-3.so.200.20.0" "${OUTDIR}/libnl-genl-3.so.200.20.0"
cp -a "${SDK}/targets/96813GW/fs/usr/lib/libceshared.so"       "${OUTDIR}/libceshared.so"
echo "=== hostapd daemon -> ${OUTDIR}/hostapd ==="
exit 0

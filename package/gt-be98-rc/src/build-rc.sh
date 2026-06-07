#!/usr/bin/env bash
# gt-be98-rc from-source LINK (promoted from the proven output-rclink harness).
# rc already COMPILES from source; this drives the LINK via the merlin SDK
# build-glue (same env as gt-be98-libshared) + the SDK-version selector:
#   ASUSWRT_BRCM_SDK_VERSION=WIFI7_SDK_20231126  -> the GT-BE98 `_be` prebuild .o
#   SRCBASE = WL impl (bcm96813/main/src)        -> wlioctl/typedefs/bcmnvram graph
#   HND_SRC = SDK top                            -> bcmdrivers/userspace graph
#   CFLAGS  = router Makefile's fully-expanded defines incl. -DGTBE98 (env-exported
#             so rc/Makefile's `CFLAGS +=` appends) PLUS -L<OUTDIR>/graftlibs.
#
# Link closure (LDFLAGS2 in rc/Makefile): from-source libshared
# (router/shared, built by gt-be98-libshared) + libnvram (router-sysdep/nvram,
# soname satisfied at runtime by clean-room gt-be98-nvram) + the irreducible
# Broadcom core already built in the SDK tree (router-sysdep/* and router/*) +
# libwpa_client staged here as a pinned graft (its in-Makefile -L path is empty
# for this config). All other -L dirs the Makefile names already hold their .so.
#
# Args / env (set by the Buildroot .mk):
#   GTBE98_ROOT   firmware root (.../gt-be98-firmware)
#   SDK           .../release/src-rt-5.04behnd.4916
#   PKG_SRC       this package's src/ (holds cflags.template.txt)
#   OUTDIR        where to drop rc (the Buildroot $(@D))
set -uo pipefail

: "${GTBE98_ROOT:?GTBE98_ROOT unset}"
: "${SDK:?SDK unset}"
: "${PKG_SRC:?PKG_SRC unset}"
: "${OUTDIR:?OUTDIR unset}"

export GTBE98_ROOT
export GTBE98_TC_ROOT="${GTBE98_ROOT}/toolchain/am-toolchains/brcm-arm-hnd"
export SRCBASE="${SDK}/bcmdrivers/broadcom/net/wl/bcm96813/main/src"
export HND_SRC="${SDK}/"
export GTBE98=y
export BUSYBOX_DIR=busybox
export BCM_WLIMPL=103
export ASUSWRT_BRCM_SDK_VERSION=WIFI7_SDK_20231126
export WLAN_ComponentSrcDirs="${SDK}/bcmdrivers/broadcom/net/wl/impl103/main/components/proto/src ${SDK}/bcmdrivers/broadcom/net/wl/impl103/main/components/wlioctl/src ${SDK}/bcmdrivers/broadcom/net/wl/impl103/main/src/shared/bcmwifi/src"
export WLAN_StdIncPathA="-I${SDK}/bcmdrivers/broadcom/net/wl/impl103/main/src/include -I${SDK}/bcmdrivers/broadcom/net/wl/impl103/main/src/shared"

# Stage the pinned graft -L dir: libwpa_client (built in the impl103 components
# tree; the rc Makefile's own -L path for it is empty in this config).
GRAFT="${OUTDIR}/graftlibs"
mkdir -p "${GRAFT}"
WPA="${SDK}/bcmdrivers/broadcom/net/wl/impl103/main/components/opensource/router_tools/wpa_supplicant/wpa_supplicant/libwpa_client.so"
[ -e "${WPA}" ] && ln -sf "${WPA}" "${GRAFT}/libwpa_client.so"

# CFLAGS from the tokenised template (portable across firmware roots) + graft -L.
export CFLAGS="$(sed -e "s|@SDK@|${SDK}|g" -e "s|@ROOT@|${GTBE98_ROOT}|g" "${PKG_SRC}/cflags.template.txt") -L${GRAFT}"

# merlin host-env sanitiser + cross toolchain (gcc-10.3). unset LD_LIBRARY_PATH
# else host cc1 breaks.
source "${GTBE98_ROOT}/tools/sanitize-host-env.sh"; gtbe98_sanitize_ld_library_path
source "${GTBE98_ROOT}/tools/env.sh";              gtbe98_sanitize_ld_library_path

cd "${SDK}/router"
env -u LD_LIBRARY_PATH make -C rc rc \
    SRCBASE="${SRCBASE}" HND_SRC="${HND_SRC}" \
    GTBE98_TC_ROOT="${GTBE98_TC_ROOT}" GTBE98_ROOT="${GTBE98_ROOT}" \
    ASUSWRT_BRCM_SDK_VERSION="${ASUSWRT_BRCM_SDK_VERSION}" \
    LD_LIBRARY_PATH= SHELL=/bin/bash
rc=$?
echo "=== make -C rc rc rc=${rc} ==="
[ "${rc}" -ne 0 ] && exit "${rc}"

cp -a "${SDK}/router/rc/rc" "${OUTDIR}/rc"
echo "=== rc -> ${OUTDIR}/rc ==="
exit 0

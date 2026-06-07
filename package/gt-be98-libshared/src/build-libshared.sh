#!/usr/bin/env bash
# gt-be98-libshared from-source build (promoted from the proven output-sdkglue
# harness). Builds router/shared -> libshared.so via the merlin SDK build-glue:
#   SRCBASE = WL impl (bcm96813/main/src)  -> wlioctl/typedefs/bcmnvram graph
#   HND_SRC = SDK top                       -> bcmdrivers/userspace graph
#   CFLAGS  = router Makefile's fully-expanded defines incl. -DGTBE98, exported
#             via ENV so shared/Makefile's `CFLAGS +=` appends (cmdline clobbers).
# The 15 closed + 4 SDK-buildable prebuild/*.o stay as graft inputs, linked by
# the Makefile's prebuild/%.o rules. Result copied to $OUTDIR/libshared.{so,a}.
#
# Args / env (set by the Buildroot .mk):
#   GTBE98_ROOT   firmware root (.../gt-be98-firmware)
#   SDK           .../release/src-rt-5.04behnd.4916
#   PKG_SRC       this package's src/ (holds cflags.template.txt)
#   OUTDIR        where to drop libshared.so / libshared.a (the Buildroot $(@D))
set -uo pipefail

: "${GTBE98_ROOT:?GTBE98_ROOT unset}"
: "${SDK:?SDK unset}"
: "${PKG_SRC:?PKG_SRC unset}"
: "${OUTDIR:?OUTDIR unset}"

export GTBE98_ROOT
export GTBE98_TC_ROOT="${GTBE98_ROOT}/toolchain/am-toolchains/brcm-arm-hnd"
export SRCBASE="${SDK}/bcmdrivers/broadcom/net/wl/bcm96813/main/src"
export HND_SRC="${SDK}/"
# Materialise CFLAGS from the tokenised template (portable across firmware roots).
export CFLAGS="$(sed -e "s|@SDK@|${SDK}|g" -e "s|@ROOT@|${GTBE98_ROOT}|g" "${PKG_SRC}/cflags.template.txt")"
export GTBE98=y
export BUSYBOX_DIR=busybox
export BCM_WLIMPL=103
export WLAN_ComponentSrcDirs="${SDK}/bcmdrivers/broadcom/net/wl/impl103/main/components/proto/src ${SDK}/bcmdrivers/broadcom/net/wl/impl103/main/components/wlioctl/src ${SDK}/bcmdrivers/broadcom/net/wl/impl103/main/src/shared/bcmwifi/src"
export WLAN_StdIncPathA="-I${SDK}/bcmdrivers/broadcom/net/wl/impl103/main/src/include -I${SDK}/bcmdrivers/broadcom/net/wl/impl103/main/src/shared"

# merlin host-env sanitiser + cross toolchain (gcc-10.3). unset LD_LIBRARY_PATH
# else host cc1 breaks.
source "${GTBE98_ROOT}/tools/sanitize-host-env.sh"; gtbe98_sanitize_ld_library_path
source "${GTBE98_ROOT}/tools/env.sh";              gtbe98_sanitize_ld_library_path

cd "${SDK}/router"
env -u LD_LIBRARY_PATH make -C shared \
    SRCBASE="${SRCBASE}" HND_SRC="${HND_SRC}" \
    GTBE98_TC_ROOT="${GTBE98_TC_ROOT}" GTBE98_ROOT="${GTBE98_ROOT}" \
    LD_LIBRARY_PATH= SHELL=/bin/bash
rc=$?
echo "=== make -C shared rc=${rc} ==="
[ "${rc}" -ne 0 ] && exit "${rc}"

cp -a "${SDK}/router/shared/libshared.so" "${OUTDIR}/libshared.so"
cp -a "${SDK}/router/shared/libshared.a"  "${OUTDIR}/libshared.a"
echo "=== libshared.so -> ${OUTDIR}/libshared.so ==="
exit 0

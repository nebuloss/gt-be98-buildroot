#!/usr/bin/env bash
# gt-be98-hostapd FULL DAEMON from-source build via the merlin SDK build-glue.
#
# Drives the vendor router target `make -C router hostapd`, which sets up the
# full export env (TOP/TOP_PLATFORM/BRCM_CHIP + PKG_CONFIG_PATH for libnl +
# the cross LD) and recurses into the hostapd brcm.config build:
#   DRIVER_BRCM + NL80211 + MLO/MAP/SAE/OWE/HS20/WPS, TLS=openssl, CEVENT.
# Prereqs (libnl, openssl) build from source in the SDK tree; the daemon links
# our from-source libshared + libnvram, libnl, and the pinned closed
# libceshared.so (KEEP-AS-GRAFT).
#
# OPENSSL MODE (env OPENSSL3_DEV):
#   - UNSET (default, 1.1 fallback): links the SDK's bundled openssl-1.1.1w
#     shared libs ($(TOP)/openssl). Stripped result is BYTE-IDENTICAL to the
#     shipped device hostapd (sha256 7453000858a8...; same DT_NEEDED).
#   - SET to a gt-be98-br-openssl 3.6.2 static staging tree (_brdev/usr/br):
#     STATIC-links openssl-3.6.2 libcrypto.a into hostapd (the device's SOLE
#     live openssl-1.1 consumer -> closes the EOL-1.1 gap). Drops the unused
#     -lssl (hostapd imports 0 libssl symbols; CONFIG_EAP off). The resulting
#     hostapd NEEDs NO libcrypto.so.1.1 / libssl.so.1.1 (self-contained on
#     openssl-3). No source edits: crypto_openssl.c already has the openssl-3
#     #if-branches; the same source recompiles against the openssl-3 headers.
#     Two repoints are required and applied in-build (restored on exit so the
#     1.1 fallback tree stays intact):
#       (a) hostapd/Makefile:27-28  -I$(TOP)/openssl/include / -L$(TOP)/openssl
#       (b) brcm.config:45 fs.build/public/include/openssl  (a SECOND 1.1 header
#           tree that wins by include order -> shadowed with openssl-3 headers).
#
# Args / env (set by the Buildroot .mk):
#   GTBE98_ROOT   firmware root (has toolchain/am-toolchains/brcm-arm-hnd + tools/)
#   SDK           .../release/src-rt-5.04behnd.4916 (router/ + bcmdrivers/)
#   PKG_SRC       libshared package src (for cflags.template.txt)
#   OUTDIR        where to drop hostapd (the Buildroot $(@D))
#   OPENSSL3_DEV  (optional) openssl-3.6.2 static staging dir (.../_brdev/usr/br)
set -uo pipefail
: "${GTBE98_ROOT:?}"; : "${SDK:?}"; : "${PKG_SRC:?}"; : "${OUTDIR:?}"
OPENSSL3_DEV="${OPENSSL3_DEV:-}"

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
MK="${HA}/Makefile"
FSINC="${SDK}/targets/96813GW/fs.build/public/include/openssl"

# --- openssl-3 repoint (only when OPENSSL3_DEV is set) ------------------------
cleanup_ossl3() {
	[ -f "${MK}.ossl11.bak" ] && mv -f "${MK}.ossl11.bak" "${MK}"
	if [ -e "${FSINC}.ossl11.bak" ]; then rm -rf "${FSINC}"; mv -f "${FSINC}.ossl11.bak" "${FSINC}"; fi
}
if [ -n "${OPENSSL3_DEV}" ]; then
	[ -f "${OPENSSL3_DEV}/lib/libcrypto.a" ] || { echo "FATAL: no libcrypto.a in OPENSSL3_DEV=${OPENSSL3_DEV}"; exit 4; }
	trap cleanup_ossl3 EXIT
	cp -a "${MK}" "${MK}.ossl11.bak"
	# (a) hostapd/Makefile:27-28 -> openssl-3 headers + STATIC libcrypto.a, drop -lssl, +ldl
	python3 - "${MK}" "${OPENSSL3_DEV}" <<'PY'
import sys
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
	grep -q OSSL3 "${MK}" || { echo "FATAL: Makefile openssl repoint did not apply (upstream lines changed?)"; exit 5; }
	# (b) brcm.config:45 fs.build/public/include/openssl still ships a 1.1 header
	#     tree that wins by include order -> shadow it with the openssl-3 headers.
	if [ -e "${FSINC}" ] && [ ! -L "${FSINC}" ]; then
		mv -f "${FSINC}" "${FSINC}.ossl11.bak"
		ln -s "${OPENSSL3_DEV}/include/openssl" "${FSINC}"
	fi
	echo "=== OPENSSL3 mode: static openssl-3.6.2 (${OPENSSL3_DEV}) ==="
fi

cd "${SDK}/router"
# force a clean of the hostapd objects so crypto_openssl.o recompiles vs the
# (repointed) openssl headers; libnl/openssl prereqs are otherwise unchanged.
[ -n "${OPENSSL3_DEV}" ] && env -u LD_LIBRARY_PATH make -C "${HA}" clean LD_LIBRARY_PATH= SHELL=/bin/bash >/dev/null 2>&1
env -u LD_LIBRARY_PATH make hostapd LD_LIBRARY_PATH= SHELL=/bin/bash
rc=$?
echo "=== make -C router hostapd rc=${rc} ==="
[ "${rc}" -ne 0 ] && exit "${rc}"

# NB: the daemon is built in-tree; drop it as hostapd.daemon.
cp -a "${HA}/hostapd" "${OUTDIR}/hostapd.daemon"
# Stage the daemon's from-source / pinned runtime deps for rootfs install.
if [ -z "${OPENSSL3_DEV}" ]; then
	# 1.1 mode: ship the SDK's shared openssl-1.1.1w next to the daemon.
	cp -a "${SDK}/router/openssl/libcrypto.so.1.1" "${OUTDIR}/libcrypto.so.1.1"
	cp -a "${SDK}/router/openssl/libssl.so.1.1"    "${OUTDIR}/libssl.so.1.1"
fi
# OPENSSL3 mode: openssl-3 is STATIC inside hostapd -> NO libcrypto/libssl to ship.
cp -a "${SDK}/targets/96813GW/fs/lib/libnl-3.so.200.20.0"      "${OUTDIR}/libnl-3.so.200.20.0"
cp -a "${SDK}/targets/96813GW/fs/lib/libnl-genl-3.so.200.20.0" "${OUTDIR}/libnl-genl-3.so.200.20.0"
cp -a "${SDK}/targets/96813GW/fs/usr/lib/libceshared.so"       "${OUTDIR}/libceshared.so"
echo "=== hostapd daemon -> ${OUTDIR}/hostapd.daemon ==="
exit 0

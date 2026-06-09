#!/usr/bin/env bash
# build-shim.sh — build bcm_pcie_hcd_shim.ko against the harness kernel tree.
# The harness .config (FTRACE-off, struct module = 0x280) must be staged in the
# kernel tree first (build-harness-kernel.sh does this). Run AFTER the harness
# kernel is built so modules_prepare artifacts exist.
set -euo pipefail
SDK=/home/guillaume/be98/gt-be98-firmware/vendor/asuswrt-merlin.ng/release/src-rt-5.04behnd.4916
KSRC="$SDK/kernel/linux-4.19"
TC=/home/guillaume/be98/gt-be98-firmware/toolchain/am-toolchains/brcm-arm-hnd/crosstools-aarch64-gcc-10.3-linux-4.19-glibc-2.32-binutils-2.36.1
HERE="$(cd "$(dirname "$0")" && pwd)"
export PATH="$TC/usr/bin:$TC/bin:$PATH"
cp "$HERE/../harness-kernel/config_harness" "$KSRC/.config"
make -C "$KSRC" ARCH=arm64 CROSS_COMPILE=aarch64-buildroot-linux-gnu- olddefconfig </dev/null
make -C "$KSRC" ARCH=arm64 CROSS_COMPILE=aarch64-buildroot-linux-gnu- modules_prepare </dev/null
make -C "$KSRC" M="$HERE" ARCH=arm64 CROSS_COMPILE=aarch64-buildroot-linux-gnu- modules </dev/null
echo "shim built: $HERE/bcm_pcie_hcd_shim.ko"

#!/usr/bin/env bash
# build-kernel-pkgtb.sh — from-source, vermagic-preserved GT-BE98 4.19.294 kernel
# packaged into a trial-ready .pkgtb. Two products:
#   (1) baseline  : unmodified from-source kernel  -> GT-BE98_kernel-fromsrc-base.pkgtb
#   (2) hardened  : + clean-applying 4.19.295..325 in-tree CVE backports
#
# The kernel VERSION is pinned (4.19.294); only the SOURCE is rebuilt. vermagic
# ("4.19.294 SMP preempt mod_unload aarch64") and the closed-.ko exported-symbol
# set are SACRED — never touched (no SUBLEVEL bump, no SMP/PREEMPT/MOD_UNLOAD or
# MODVERSIONS/MODULE_SIG config change).
#
# PROVEN FACTS (this tree, 2026-06-08):
#  - The from-source Image is BYTE-IDENTICAL to the kernel shipping in v31's itb
#    (decompress v31 kernel-lzo == arch/arm64/boot/Image, exact).
#  - bare `lzop < Image` reproduces v31's kernel lzo byte-for-byte (mtime-normalized).
#    => the baseline repack is byte-identical to v31's bootfs (modulo FIT timestamp).
#  - The 37 closed .ko import 1541 distinct symbols; ALL resolve against the
#    rebuilt Module.symvers + inter-.ko defs, 0 unresolved.
#  - CVE patches touch only net/crypto/fs/security/lib; the af_alg.c export delta
#    they introduce has ZERO intersection with the closed-.ko import set.
#
# KNOWN BLOCKER (hardened Image relink): a full vmlinux relink re-descends the
# bcmdrivers/bcmkernel obj-y PLATFORM drivers (board, plat-bcm, phy, ...) whose
# .o's were cleaned from this tree; regenerating them needs the SDK top-level
# orchestration (per-subdir EXTRA_CFLAGS, generated pmc/clk headers, root for
# /etc/fw). The CVE-patched net/crypto/fs/security/lib built-in.a's COMPILE
# CLEANLY (0 errors); only the final platform relink is SDK-glue-bound. See NOTES.
set -euo pipefail

SDK=/home/guillaume/be98/gt-be98-firmware/vendor/asuswrt-merlin.ng/release/src-rt-5.04behnd.4916
KSRC="$SDK/kernel/linux-4.19"
TC=/home/guillaume/be98/gt-be98-firmware/toolchain/am-toolchains/brcm-arm-hnd/crosstools-aarch64-gcc-10.3-linux-4.19-glibc-2.32-binutils-2.36.1
LZOP="$SDK/hostTools/prebuilt/GT-BE98/lzop"
V31SQ=/home/guillaume/be98/job-tmp/openrc-init-v31/out/GT-BE98_openrc-init_rootfs.squashfs
DEVITB=/home/guillaume/be98/job-tmp/openrc-init-v31/base/bcm96813GW_uboot_linux.itb
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-/home/guillaume/be98/job-tmp/kernel-fromsrc}"
ART=/home/guillaume/be98/artifacts-br

export PATH="$TC/usr/bin:$TC/bin:$PATH"
export ARCH=arm64 CROSS_COMPILE=aarch64-buildroot-linux-gnu-
export LINUX_VER_STR=4.19.294 BCM_KF=y BUILD_NAME=gt-be98 BRCM_CHIP=6813 BCM_CHIP=6813
export PROFILE_DIR="$SDK/targets/96813GW" BUILD_DIR="$SDK" SHARED_DIR="$SDK/shared"
export KERNEL_DIR="$KSRC" BRCMDRIVERS_DIR="$SDK/bcmdrivers" HND_SRC="$SDK" SRCBASE="$KSRC"
export BRCM_BOARD=bcm963xx REUSE_PREBUILT_HND=1
KCFLAGS="-I../../bcmdrivers/opensource/include/bcm963xx/ -I../../bcmdrivers/broadcom/include/bcm963xx \
 -I$SDK/kernel/bcmkernel/include -I$SDK/kernel/bcmkernel/include/uapi \
 -I$SDK/shared/opensource/include/bcm963xx -DBCA_HNDROUTER -DBCA_CPEROUTER -DGTBE98"

build_image() { # full Image build (hits the platform-relink wall on a clean tree)
  cd "$KSRC"
  make -j"$(nproc)" KCFLAGS="$KCFLAGS" ARCH=arm64 CROSS_COMPILE=aarch64-buildroot-linux-gnu- Image
}

compile_check() { # CVE subsystems only — proves the patches compile (0 errors)
  cd "$KSRC"
  make -j"$(nproc)" -k KCFLAGS="$KCFLAGS" ARCH=arm64 \
    CROSS_COMPILE=aarch64-buildroot-linux-gnu- net/ crypto/ fs/ security/ lib/
}

make_pkgtb() { # $1=Image  $2=out.pkgtb   (mtime-normalized lzo -> swap into device itb -> repack)
  local IMG="$1" OUT="$2"
  cp "$IMG" "$WORK/Image.tmp"; touch -d @$((0x6a22ddf8)) "$WORK/Image.tmp"
  "$LZOP" < "$WORK/Image.tmp" > "$WORK/kernel.lzo"
  python3 "$HERE/swap-kernel-itb.py" "$WORK/kernel.lzo" "$WORK/new.itb" "$WORK"
  python3 "$HERE/repack-pkgtb.py" "$WORK/new.itb" "$V31SQ" "$OUT"
  dumpimage -l "$OUT" | head -25
}

case "${1:-help}" in
  baseline)   build_image; make_pkgtb "$KSRC/arch/arm64/boot/Image" "$ART/GT-BE98_kernel-fromsrc-base.pkgtb" ;;
  cve-apply)  python3 "$HERE/curate-cve.py" ;;
  cve-check)  compile_check ;;
  hardened)   build_image; make_pkgtb "$KSRC/arch/arm64/boot/Image" "$ART/GT-BE98_kernel-cve-hardened.pkgtb" ;;
  *) echo "usage: $0 {baseline|cve-apply|cve-check|hardened}"; exit 1 ;;
esac

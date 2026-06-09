#!/usr/bin/env bash
# build-harness-kernel.sh — CP-1 of the open-brcmfmac roadmap.
#
# Builds the DISPOSABLE "harness kernel": the merlin 4.19.294 aarch64 source
# reconfigured to BOOT under a GENERIC `qemu-system-aarch64 -M virt` machine
# (NOT the real BCM6813/6717 SoC), while KEEPING the EXPORT_SYMBOLs the closed
# dhd.ko dep-chain needs (nbuff/blog/bcm_knvram + the 276 merlin-only vmlinux
# symbols dhd's deps import). This kernel is RESEARCH-ONLY and NEVER flashed.
#
# What it changes vs the committed kernel-cve baseline (all reversible):
#   1. config: + PCI_HOST_GENERIC + VIRTIO_{PCI,MMIO,BLK,CONSOLE,NET}
#      + FTRACE/KPROBES/KGDB/DYNAMIC_DEBUG (IPC-capture instrumentation).
#      (config_gt-be98 + qemu-harness/harness-kernel/config_harness fragment)
#   2. source: bcm_ubus_dt.c bcm_ubus_drv_init() gets an `#ifdef BCM_QEMU_HARNESS`
#      early-return BEFORE bcm_ubus_config() — that postcore_initcall writes to a
#      SoC UBUS-fabric MMIO register absent on -M virt and hard-faults
#      (see traces/merlin-kernel-virt-panic.log). The guard is compile-time:
#      KCFLAGS injects -DBCM_QEMU_HARNESS, so a normal device build is byte-untouched.
#
# vermagic ("4.19.294 SMP preempt mod_unload aarch64") and the closed-.ko export
# set are UNCHANGED (no SUBLEVEL/SMP/PREEMPT/MOD_UNLOAD/MODVERSIONS/MODULE_SIG
# delta) so the dhd module-load ABI stays intact.
#
# Build env is verbatim from board/gt-be98/kernel-cve/build-kernel-pkgtb.sh
# (the PROVEN from-source relink recipe).
set -euo pipefail

SDK=/home/guillaume/be98/gt-be98-firmware/vendor/asuswrt-merlin.ng/release/src-rt-5.04behnd.4916
KSRC="$SDK/kernel/linux-4.19"
TC=/home/guillaume/be98/gt-be98-firmware/toolchain/am-toolchains/brcm-arm-hnd/crosstools-aarch64-gcc-10.3-linux-4.19-glibc-2.32-binutils-2.36.1
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-/home/guillaume/be98/job-tmp/cp1-harness}"
OUT="$HERE/Image"            # the harness Image lands here (committed pointer in README)
BKDIR="$WORK/baseline-backup"

export PATH="$TC/usr/bin:$TC/bin:$PATH"
export ARCH=arm64 CROSS_COMPILE=aarch64-buildroot-linux-gnu-
export LINUX_VER_STR=4.19.294 BCM_KF=y BUILD_NAME=gt-be98 BRCM_CHIP=6813 BCM_CHIP=6813
export PROFILE_DIR="$SDK/targets/96813GWO_WL23D2GA" BUILD_DIR="$SDK" SHARED_DIR="$SDK/shared"
export KERNEL_DIR="$KSRC" BRCMDRIVERS_DIR="$SDK/bcmdrivers" HND_SRC="$SDK" SRCBASE="$KSRC"
export BRCM_BOARD=bcm963xx REUSE_PREBUILT_HND=1
export INC_BRCMDRIVER_PUB_PATH="$SDK/bcmdrivers/opensource/include"
export INC_BRCMDRIVER_PRIV_PATH="$SDK/bcmdrivers/broadcom/include"
export INC_BRCMSHARED_PUB_PATH="$SDK/shared/opensource/include"
export INC_BRCMSHARED_PRIV_PATH="$SDK/shared/broadcom/include"
export BRCM_BOARD_ID="GT-BE98" BRCM_NUM_MAC_ADDRESSES=11 BRCM_BASE_MAC_ADDRESS="20:CF:30:00:00:00"
export INSTALL_DIR="${INSTALL_DIR:-$WORK/fs.install}"

# -DBCM_QEMU_HARNESS activates the bcm_ubus_dt.c early-return stub.
KCFLAGS="-DBCM_QEMU_HARNESS \
 -I../../bcmdrivers/opensource/include/bcm963xx/ -I../../bcmdrivers/broadcom/include/bcm963xx \
 -I$SDK/kernel/bcmkernel/include -I$SDK/kernel/bcmkernel/include/uapi \
 -I$SDK/shared/opensource/include/bcm963xx -DBCA_HNDROUTER -DBCA_CPEROUTER -DGTBE98"

# Stage config_harness into .config and resolve NEW symbols. On this tree
# `make syncconfig` behaves like oldconfig and PROMPTS for NEW symbols, so feed
# blank lines (= take each NEW symbol's default). Run this ONCE before build;
# the result persists in $KSRC/.config + include/config/auto.conf.
#
# ⚠️ CAVEAT: the prompt-feeding `yes "" | make syncconfig` is reliable from an
# interactive shell but can stall in a fully-detached (non-tty) background run.
# If you build in the background and `make Image` doesn't start, run this sync
# step ONCE in the foreground first, then re-run `build` (it skips the re-sync
# via the BCM_QEMU_HARNESS_SYNCED marker in include/config/auto.conf).
syncconfig() {
  cd "$KSRC"
  cp "$HERE/config_harness" .config
  yes "" | make syncconfig
}

PATCH="$HERE/0001-soc-initcall-stubs-for-qemu-virt-harness.patch"

build() {
  mkdir -p "$INSTALL_DIR/etc/fw" "$WORK"
  # Apply the SoC-initcall stubs to the SDK source IN PLACE (the #ifdef guards are
  # inert without -DBCM_QEMU_HARNESS, but KCFLAGS adds it). Revert on exit so the
  # committed kernel-cve baseline source is never left perturbed.
  ( cd "$SDK" && git apply --check "$PATCH" 2>/dev/null && git apply "$PATCH" && echo "stub patch applied" ) || \
    ( cd "$SDK" && git apply --reverse --check "$PATCH" 2>/dev/null && echo "stub patch already applied" )
  trap '( cd "$SDK" && git apply --reverse "$PATCH" 2>/dev/null && echo "stub patch reverted" ); restore_baseline' EXIT

  cd "$KSRC"
  # Sync .config from config_harness once (syncconfig prompts for NEW symbols —
  # feed blank-line defaults). A source-only rebuild needs no re-sync.
  if [ ! -f include/config/auto.conf ] || ! grep -q BCM_QEMU_HARNESS_SYNCED include/config/auto.conf 2>/dev/null; then
    syncconfig
    echo "# BCM_QEMU_HARNESS_SYNCED" >> include/config/auto.conf
  fi
  make -j"$(nproc)" KCFLAGS="$KCFLAGS" ARCH=arm64 \
    CROSS_COMPILE=aarch64-buildroot-linux-gnu- Image
  mkdir -p "$HERE"
  cp "$KSRC/arch/arm64/boot/Image" "$OUT"
  cp "$KSRC/vmlinux"    "$WORK/vmlinux.harness"     # for gdb/kgdb symbols
  cp "$KSRC/System.map" "$WORK/System.map.harness"
  echo "==== harness Image -> $OUT ===="
  ls -l "$OUT"
  # EXIT trap reverts the patch + restores the baseline Image/.config/vmlinux.
}

# Restore the committed kernel-cve baseline (.config + the SoC-coupled vmlinux/Image)
# so this research build never perturbs it. The stub patch is git-reverted separately.
restore_baseline() {
  cd "$KSRC"
  [ -f "$BKDIR/config.orig" ]  && cp "$BKDIR/config.orig"  .config
  [ -f "$BKDIR/Image.orig" ]   && cp "$BKDIR/Image.orig"   arch/arm64/boot/Image
  [ -f "$BKDIR/vmlinux.orig" ] && cp "$BKDIR/vmlinux.orig" vmlinux
  echo "baseline restored"
}

case "${1:-build}" in
  build)   build ;;
  restore) ( cd "$SDK" && git apply --reverse "$PATCH" 2>/dev/null || true ); restore_baseline ;;
  *) echo "usage: $0 {build|restore}"; exit 1 ;;
esac

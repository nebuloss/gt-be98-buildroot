#!/bin/sh
# Boot the stock 4.19.294 kernel under qemu-system-aarch64 -M virt with the
# broadcom-fmac-stub PCI device-model + the probe initramfs, and capture the
# full host<->device IPC handshake trace.
#
#   ./run-harness.sh [extra -device props]   e.g. ipc-rev=8,chipid=0x6726
#
# Trace goes to qemu-harness/traces/handshake.log
set -e
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/scripts/config.env"

DEVPROPS=${1:-}
DEV="broadcom-fmac-stub"
[ -n "$DEVPROPS" ] && DEV="$DEV,$DEVPROPS"

LOG="$HERE/traces/handshake.log"
mkdir -p "$HERE/traces"

# -d guest_errors,unimp logs unmodeled accesses; the device-model's own
# qemu_log() lines (bcm-fmac-stub: ...) interleave with the kernel console.
timeout 40 "$QEMU" \
  -M virt -cpu cortex-a72 -smp 1 -m 1024 \
  -kernel "$STOCK_IMAGE" \
  -initrd "$HERE/rootfs/initramfs-probe.cpio.gz" \
  -append "console=ttyAMA0 loglevel=8 rdinit=/init dyndbg" \
  -device "$DEV" \
  -nographic -no-reboot \
  -d guest_errors \
  2>&1 | tee "$LOG"

echo
echo "==== trace saved to $LOG ===="
echo "==== device-model IPC lines ===="
grep -E 'bcm-fmac-stub|bcmfmac-probe' "$LOG" || true

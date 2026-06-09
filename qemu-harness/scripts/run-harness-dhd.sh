#!/bin/sh
# run-harness-dhd.sh — CP-1 verification run.
# Boot the HARNESS kernel (merlin 4.19.294 + virt + ubus-stub, exports dhd's deps)
# under qemu-system-aarch64 -M virt with the broadcom-fmac-stub PCI device-model +
# the dhd initramfs, and capture the dhd dep-chain load + dhd.ko probe attempt
# against the emulated Broadcom PCIe device.
#
#   ./run-harness-dhd.sh [extra -device props]   e.g. ipc-rev=8,chipid=0x6726
#   GDB=1 ./run-harness-dhd.sh ...               # also open the gdbstub (-s -S)
#
# Trace -> qemu-harness/traces/dhd-harness.log
set -e
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/scripts/config.env"

DEVPROPS=${1:-}
DEV="broadcom-fmac-stub"
[ -n "$DEVPROPS" ] && DEV="$DEV,$DEVPROPS"

LOG="$HERE/traces/dhd-harness.log"
mkdir -p "$HERE/traces"

GDBOPT=""
[ "${GDB:-0}" = "1" ] && GDBOPT="-s -S"   # gdbstub on :1234, halt at reset

# The merlin amba-pl011 runtime console does NOT enable on -M virt (its clock is
# set up by the SoC init we stubbed), so we drive output through earlycon and
# reflow it with clean-earlycon-log.py. dyndbg turns on dhd's verbose IPC
# complaints; init.c also enables module-scoped dynamic_debug before each load.
timeout "${TIMEOUT:-70}" "$QEMU" \
  -M virt -cpu cortex-a72 -smp 1 -m 1024 \
  -kernel "$HARNESS_IMAGE" \
  -initrd "$HERE/rootfs/initramfs-dhd.cpio.gz" \
  -append "earlycon=pl011,0x9000000 keep_bootcon console=ttyAMA0 loglevel=8 rdinit=/init dyndbg=\"module dhd +p\"" \
  -device "$DEV" \
  -nographic -no-reboot \
  -d guest_errors \
  $GDBOPT \
  2>&1 | python3 "$HERE/scripts/clean-earlycon-log.py" | awk '!seen[$0]++' | tee "$LOG"

echo
echo "==== trace saved to $LOG ===="
echo "==== device-model + module-load lines ===="
grep -E 'bcm-fmac-stub|finit_module|-> (OK|FAIL)|Unknown symbol|resolve_symbol|0000:00:0.\.0 vendor=|PROBE|chipid|IPC|SHARED' "$LOG" || true

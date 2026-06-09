#!/bin/sh
# Inject the broadcom-fmac-stub device-model into a QEMU source tree and build
# qemu-system-aarch64. Idempotent. Run once; rerun after editing the stub.
#
#   ./apply-to-qemu.sh /path/to/qemu-10.0.0
#
set -e
QSRC=${1:-/home/guillaume/qemu-src/qemu-10.0.0}
HERE=$(cd "$(dirname "$0")/.." && pwd)

cp "$HERE/device-model/broadcom-fmac-stub.c" "$QSRC/hw/misc/broadcom-fmac-stub.c"

# Kconfig: always-on (default y), not gated behind TEST_DEVICES
if ! grep -q BROADCOM_FMAC_STUB "$QSRC/hw/misc/Kconfig"; then
  python3 - "$QSRC/hw/misc/Kconfig" <<'PY'
import sys
f=sys.argv[1]; s=open(f).read()
b="config BROADCOM_FMAC_STUB\n    bool\n    default y\n    depends on PCI && MSI_NONBROKEN\n\n"
open(f,'w').write(s.replace('config EDU\n', b+'config EDU\n',1))
PY
fi

# meson: build the source when the config symbol is set
if ! grep -q broadcom-fmac-stub.c "$QSRC/hw/misc/meson.build"; then
  python3 - "$QSRC/hw/misc/meson.build" <<'PY'
import sys
f=sys.argv[1]; s=open(f).read()
ln="system_ss.add(when: 'CONFIG_BROADCOM_FMAC_STUB', if_true: files('broadcom-fmac-stub.c'))\n"
anchor="system_ss.add(when: 'CONFIG_EDU', if_true: files('edu.c'))\n"
open(f,'w').write(s.replace(anchor, anchor+ln,1))
PY
fi

if [ ! -d "$QSRC/build" ]; then
  ( cd "$QSRC" && ./configure --target-list=aarch64-softmmu \
      --disable-docs --disable-werror --enable-debug )
fi
ninja -C "$QSRC/build" qemu-system-aarch64
echo "OK: $QSRC/build/qemu-system-aarch64"

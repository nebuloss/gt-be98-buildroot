#!/bin/sh
# Build the bcmfmac-probe.ko exerciser module against the stock 4.19.294 kernel,
# build the static aarch64 init, and assemble a cpio initramfs containing init +
# the probe module. (The closed dhd.ko path uses build-initramfs-dhd.sh instead.)
set -e
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/scripts/config.env"

export ARCH=arm64
export CROSS_COMPILE="$CROSS"
export PATH=/usr/bin:/bin:"$TC"

# 1. build the probe module out-of-tree against the stock kernel
MB="$HERE/device-model"
cat > "$MB/Kbuild" <<'EOF'
obj-m := bcmfmac_probe.o
bcmfmac_probe-y := bcmfmac-probe.o
EOF
# kbuild wants the object name to match; create a symlink with underscore
ln -sf bcmfmac-probe.c "$MB/bcmfmac_probe.c" 2>/dev/null || true
cat > "$MB/Kbuild" <<'EOF'
obj-m := bcmfmac_probe.o
EOF
make -C "$STOCK_KSRC" M="$MB" modules
echo "built: $MB/bcmfmac_probe.ko"

# 2. static init
"${CROSS}gcc" -static -O2 -o "$HERE/rootfs/init" "$HERE/rootfs/init.c"

# 3. assemble initramfs
R="$HERE/rootfs/root"
rm -rf "$R"; mkdir -p "$R/proc" "$R/sys" "$R/dev"
cp "$HERE/rootfs/init"            "$R/init"
cp "$MB/bcmfmac_probe.ko"         "$R/bcmfmac_probe.ko"
( cd "$R" && find . | cpio -o -H newc 2>/dev/null | gzip -9 ) > "$HERE/rootfs/initramfs-probe.cpio.gz"
echo "initramfs: $HERE/rootfs/initramfs-probe.cpio.gz"

#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# Build the read-only NAND tools as static aarch64 binaries that also run on
# the STOCK firmware (Linux 4.19), for nand-ecc-compare.sh:
#   nanddump          mtd-utils (the version in the Buildroot output)
#   gt-be98-nandtool  package/gt-be98-os/src/nandtool.c
# The Buildroot glibc refuses kernels older than its headers (7.1), so this
# uses the build host's Debian cross toolchain (aarch64-linux-gnu-gcc, glibc
# for kernels >= 3.7). Output: $OUT/images/nand-tools/ (+ the scripts and a
# SHA256SUMS), the directory to copy to /tmp/gtb on both systems.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
EXT=$(cd "$HERE/../../.." && pwd)
CONF=${GT_BE98_LOCAL_CONF:-$HOME/.config/gt-be98-os/local.conf}
OUT=
. "$CONF"
CC=${CC:-aarch64-linux-gnu-gcc}
STRIP=${STRIP:-aarch64-linux-gnu-strip}
MTD=$(ls -d "$OUT"/build/mtd-[0-9]* | head -n1)
D=$OUT/images/nand-tools
rm -rf "$D"; mkdir -p "$D"
(cd "$MTD" && $CC -static -O2 -Iinclude -I. -include config.h -o "$D/nanddump" \
	nand-utils/nanddump.c lib/libmtd.c lib/libmtd_legacy.c lib/common.c)
$CC -static -O2 -Wall -o "$D/gt-be98-nandtool" "$EXT/package/gt-be98-os/src/nandtool.c"
$STRIP "$D/nanddump" "$D/gt-be98-nandtool"
cp "$HERE/nand-ecc-compare.sh" "$HERE/stock-nandinfo.sh" "$D/"
(cd "$D" && sha256sum nanddump gt-be98-nandtool nand-ecc-compare.sh stock-nandinfo.sh > SHA256SUMS)
file "$D/nanddump" "$D/gt-be98-nandtool"
cat "$D/SHA256SUMS"

#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# Static tools and scripts for NAND phase 2 (NAND-PHASE2.md, RESTORE.md),
# built with the Debian cross toolchain (they run on stock 4.19 and on
# mainline): $OUT/images/nand-phase2-kit/
#   gt-be98-ubileb, gt-be98-nandrestore, gt-be98-nandtool, nanddump,
#   ubinfo, ubimkvol, ubirmvol (mtd-utils, for stock: G7 create/remove)
#   stock-mltest.sh, mltest-mainline.sh, g7-compare.sh, stock-nandinfo.sh,
#   jffs-mainline.sh, stock-jffs-check.sh (G8),
#   patternA.bin, patternB.bin (G7)
#   SHA256SUMS
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
EXT=$(cd "$HERE/../../.." && pwd)
CONF=${GT_BE98_LOCAL_CONF:-$HOME/.config/gt-be98-os/local.conf}
OUT=
. "$CONF"
CC=${CC:-aarch64-linux-gnu-gcc}
STRIP=${STRIP:-aarch64-linux-gnu-strip}
M=$(ls -d "$OUT"/build/mtd-[0-9]* | head -n1)
D=$OUT/images/nand-phase2-kit
rm -rf "$D"; mkdir -p "$D"
$CC -static -O2 -Wall -o "$D/gt-be98-ubileb" "$HERE/src/ubileb.c"
$CC -static -O2 -Wall -o "$D/gt-be98-nandrestore" "$HERE/src/nandrestore.c"
$CC -static -O2 -Wall -o "$D/gt-be98-nandtool" "$EXT/package/gt-be98-os/src/nandtool.c"
(cd "$M" && $CC -static -O2 -Iinclude -I. -include include/config.h -o "$D/nanddump" \
	nand-utils/nanddump.c lib/libmtd.c lib/libmtd_legacy.c lib/common.c lib/libcrc32.c)
for u in ubinfo ubimkvol ubirmvol; do
	(cd "$M" && $CC -static -O2 -Iinclude -I. -include include/config.h -o "$D/$u" \
		ubi-utils/$u.c lib/libubi.c lib/libmtd.c lib/libmtd_legacy.c lib/common.c lib/libcrc32.c)
done
$STRIP "$D"/gt-be98-* "$D/nanddump" "$D/ubinfo" "$D/ubimkvol" "$D/ubirmvol"
cp "$HERE/phase2/stock-mltest.sh" "$HERE/phase2/mltest-mainline.sh" "$HERE/phase2/g7-compare.sh" \
	"$HERE/phase2/jffs-mainline.sh" "$HERE/phase2/stock-jffs-check.sh" "$HERE/stock-nandinfo.sh" "$D/"
chmod 0755 "$D"/*.sh
# deterministic G7 patterns, 4 LEBs each (126976 B)
python3 - "$D" <<'PY'
import hashlib, sys
d = sys.argv[1]
for name, seed in (("patternA.bin", b"gt-be98 G7 A"), ("patternB.bin", b"gt-be98 G7 B")):
    out, h = bytearray(), seed
    while len(out) < 4 * 126976:
        h = hashlib.sha256(h).digest()
        out += h
    open(f"{d}/{name}", "wb").write(out[:4 * 126976])
PY
(cd "$D" && sha256sum gt-be98-ubileb gt-be98-nandrestore gt-be98-nandtool nanddump \
	ubinfo ubimkvol ubirmvol stock-mltest.sh mltest-mainline.sh g7-compare.sh \
	jffs-mainline.sh stock-jffs-check.sh stock-nandinfo.sh patternA.bin patternB.bin > SHA256SUMS)
cat "$D/SHA256SUMS"

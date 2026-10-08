#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# READ-ONLY stock vs mainline ECC comparison (NAND.md, "ECC comparison").
# Runs unchanged on the stock firmware (busybox) and on the mainline OS, with
# the SAME static tools (nanddump, gt-be98-nandtool) from the build host:
#
#   T=/tmp/gtb; mkdir -p $T; copy nanddump, gt-be98-nandtool, this script to $T
#   /bin/busybox sh $T/nand-ecc-compare.sh $T > /dev/null      (stock)
#   sh $T/nand-ecc-compare.sh $T > /dev/null                    (mainline)
#   -> $T/ecccmp-<stock|mainline>/ (report.txt, pebmap.txt, dumps): tar it
#
# What it does (nothing is written to the NAND; only reads):
#   1. records the MTD ECC counters (corrected_bits, ecc_failures);
#   2. maps every PEB of the "image" partition to its UBI volume/LEB from
#      the EC/VID headers (gt-be98-nandtool pebmap);
#   3. dumps, raw (-n) and ECC-corrected, every page of: bootfs2 (vol 5)
#      LEBs 0 and 57, rootfs2 (vol 6) LEB 0, jffs2 (vol 13) LEB 0, one free
#      PEB, and the first two blocks of "loader";
#   4. per block: bitflips between raw and corrected data (programmed vs
#      erased pages, worst 512-B sector), sha256 of the corrected data and
#      of the raw OOB;
#   5. records the counters again (the delta is what these reads cost).
# Compare the two report.txt files: same geometry, same corrected-data
# sha256 for the static blocks, raw OOB identical up to the bitflips,
# flips well below the BCH-8 limit, no uncorrectable reads.
set -u
T=${1:?usage: nand-ecc-compare.sh TOOLDIR}
ND=$T/nanddump
NT=$T/gt-be98-nandtool
[ -x "$ND" ] && [ -x "$NT" ] || { echo "need $ND and $NT" >&2; exit 1; }
if grep -q 'ubi.block=' /proc/cmdline; then SYS=stock; else SYS=mainline; fi
O=$T/ecccmp-$SYS
rm -rf "$O"; mkdir -p "$O"
R=$O/report.txt
exec 3>"$R"
say() { echo "$*" >&3; }

mtdnum() { sed -n "s/^mtd\([0-9]*\): [0-9a-f]* [0-9a-f]* \"$1\"$/\1/p" /proc/mtd | head -n1; }
IMG=$(mtdnum image)
LDR=$(mtdnum loader)
[ -n "$IMG" ] && [ -n "$LDR" ] || { echo "no image/loader mtd" >&2; exit 1; }
WS=$(cat /sys/class/mtd/mtd$IMG/writesize)
OOB=$(cat /sys/class/mtd/mtd$IMG/oobsize)
EB=$(cat /sys/class/mtd/mtd$IMG/erasesize)
PPB=$((EB / WS))

counters() {
	for m in $IMG $LDR; do
		say "counters $1 mtd$m $(cat /sys/class/mtd/mtd$m/name) corrected_bits $(cat /sys/class/mtd/mtd$m/corrected_bits 2>/dev/null) ecc_failures $(cat /sys/class/mtd/mtd$m/ecc_failures 2>/dev/null) bad_blocks $(cat /sys/class/mtd/mtd$m/bad_blocks 2>/dev/null)"
	done
}

say "system $SYS kernel $(uname -r)"
say "geometry writesize $WS oobsize $OOB erasesize $EB pages_per_block $PPB ecc_strength $(cat /sys/class/mtd/mtd$IMG/ecc_strength) ecc_step $(cat /sys/class/mtd/mtd$IMG/ecc_step_size)"
dmesg | grep -iE 'BCH|nand:|bad block table' | sed 's/^/log /' >&3
counters before

"$NT" pebmap /dev/mtd$IMG > "$O/pebmap.txt"
say "pebmap $(grep -c ' vol ' "$O/pebmap.txt") used $(grep -c ' free$' "$O/pebmap.txt") free $(grep -c ' bad$' "$O/pebmap.txt") bad $(grep -c 'readerr\|nohdr' "$O/pebmap.txt") other"

peb_of() { sed -n "s/^PEB \([0-9]*\) vol $1 lnum $2$/\1/p" "$O/pebmap.txt" | head -n1; }

# $1 label, $2 mtd number, $3 block index within that mtd
dumpblock() {
	local lab=$1 m=$2 b=$3 off len
	off=$((b * EB)); len=$EB
	"$ND" -q -n --oob --bb=dumpbad -s $off -l $len -f "$O/$lab.raw" /dev/mtd$m 2>>"$O/errors.txt"
	"$ND" -q    --oob --bb=dumpbad -s $off -l $len -f "$O/$lab.ecc" /dev/mtd$m 2>>"$O/errors.txt" ||
		say "block $lab ECC READ ERROR (see errors.txt)"
	"$NT" flips "$O/$lab.raw" "$O/$lab.ecc" $WS $OOB > "$O/$lab.flips"
	say "block $lab mtd$m block $b $(tail -n1 "$O/$lab.flips")"
	# corrected data alone (comparable even if the OOB sizes differ), and
	# the raw data / raw OOB alone
	say "sha256 $lab data_ecc $("$NT" data "$O/$lab.ecc" $WS $OOB | sha256sum | cut -d' ' -f1) data_raw $("$NT" data "$O/$lab.raw" $WS $OOB | sha256sum | cut -d' ' -f1) oob_raw $("$NT" oob "$O/$lab.raw" $WS $OOB | sha256sum | cut -d' ' -f1)"
}

for t in "bootfs2-leb0 5 0" "bootfs2-leb57 5 57" "rootfs2-leb0 6 0" "jffs2-leb0 13 0"; do
	set -- $t
	p=$(peb_of $2 $3)
	if [ -n "$p" ]; then dumpblock "$1-peb$p" $IMG $p; else say "block $1 not found"; fi
done
p=$(sed -n 's/^PEB \([0-9]*\) free$/\1/p' "$O/pebmap.txt" | head -n1)
[ -n "$p" ] && dumpblock "free-peb$p" $IMG $p
dumpblock loader-blk0 $LDR 0
dumpblock loader-blk1 $LDR 1

counters after
say "done"
exec 3>&-
echo "$R"

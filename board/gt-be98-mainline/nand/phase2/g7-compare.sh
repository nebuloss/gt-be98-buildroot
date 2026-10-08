#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# G7 step 4: compare two stock-nandinfo.sh reports (stock firmware, before
# step 1 and after step 4), on the build host or on the box.
#
#   g7-compare.sh BEFORE.txt AFTER.txt [BOOTFS1_SHA256]
#
# PASS needs: the same UBI volumes (ignoring mltest) with the same type,
# reserved_ebs and data size (bootfs1: size not compared), none corrupted, no update marker; the static
# volume sha256s unchanged except bootfs1 (vol 3), which must equal
# BOOTFS1_SHA256 when given (the G7 itb that was flashed); ecc_failures and
# bad_blocks unchanged on every MTD device; "corrupted PEBs: 0" in AFTER if
# the attach line is in its log. corrected_bits deltas are printed (reads
# that needed correction: expected, not a failure).
set -u
B=$1 A=$2 BOOT1=${3:-}
fail=0
sec() {	# $1 file, $2 section header regexp: the section's lines
	awk -v h="$2" '$0 ~ "^== " || $0 ~ "^-- " { on = ($0 ~ h) ; next } on' "$1"
}
vols() { sec "$1" '^== ubi' | awk 'NF == 7 && $1 ~ /^[0-9]+$/ && $2 != "mltest" { if ($1 == 3) $5 = "(bootfs1)"; print }'; }
shas() { sec "$1" 'sha256 of the static volumes' | awk 'NF == 3'; }
mtds() { sec "$1" '^== mtd sysfs' | awk '$1 ~ /^mtd[0-9]+$/'; }

echo "== UBI volumes (id name type reserved_ebs data_bytes corrupted upd_marker)"
vols "$B" > /tmp/g7c.b.$$; vols "$A" > /tmp/g7c.a.$$
if cmp -s /tmp/g7c.b.$$ /tmp/g7c.a.$$; then echo "same: OK"; else
	echo "DIFFERENT:"; diff /tmp/g7c.b.$$ /tmp/g7c.a.$$; fail=1
fi
rm -f /tmp/g7c.b.$$ /tmp/g7c.a.$$
vols "$A" | awk '$6 != 0 || $7 != 0 { print "corrupted or update marker: " $0; bad = 1 } END { exit bad }' || fail=1

echo "== static volume sha256"
shas "$B" > /tmp/g7c.b.$$; shas "$A" > /tmp/g7c.a.$$
while read -r n name sha; do
	now=$(awk -v n="$n" '$1 == n { print $3 }' /tmp/g7c.a.$$)
	if [ "$n" = ubi0_3 ]; then
		if [ -n "$BOOT1" ]; then
			[ "$now" = "$BOOT1" ] && echo "$n $name = flashed G7 itb: OK" ||
				{ echo "$n $name: $now, expected the G7 itb $BOOT1: FAIL"; fail=1; }
		else
			echo "$n $name: $now (bootfs1, reflashed: not compared)"
		fi
	elif [ "$now" = "$sha" ]; then
		echo "$n $name unchanged: OK"
	else
		echo "$n $name CHANGED: $sha -> ${now:-<missing>}: FAIL"; fail=1
	fi
done < /tmp/g7c.b.$$
rm -f /tmp/g7c.b.$$ /tmp/g7c.a.$$

echo "== MTD counters (corrected_bits ecc_failures bad_blocks)"
mtds "$B" > /tmp/g7c.b.$$; mtds "$A" > /tmp/g7c.a.$$
while read -r m rest; do
	set -- $rest; bc=${10:-} bf=${11:-} bb=${12:-}
	set -- x $(awk -v m="$m" '$1 == m { $1 = ""; print }' /tmp/g7c.a.$$)
	ac=${11:-} af=${12:-} ab=${13:-}
	echo "$m: corrected_bits $bc -> $ac, ecc_failures $bf -> $af, bad_blocks $bb -> $ab"
	[ "$bf" = "$af" ] && [ "$bb" = "$ab" ] || { echo "  ecc_failures or bad_blocks changed: FAIL"; fail=1; }
done < /tmp/g7c.b.$$
rm -f /tmp/g7c.b.$$ /tmp/g7c.a.$$

echo "== attach log"
if grep -q 'corrupted PEBs' "$A"; then
	grep 'corrupted PEBs' "$A"
	grep -q 'corrupted PEBs: 0' "$A" || { echo "corrupted PEBs: FAIL"; fail=1; }
else
	echo "(attach line not in the AFTER log: check ubinfo / dmesg by hand)"
fi
grep -iE 'ubi[0-9]* (error|warning)|ubifs error|uncorrectable|ecc error' "$A" && { echo "errors in the AFTER log: FAIL"; fail=1; }

[ $fail = 0 ] && echo "G7-COMPARE PASS" || echo "G7-COMPARE FAIL"
exit $fail

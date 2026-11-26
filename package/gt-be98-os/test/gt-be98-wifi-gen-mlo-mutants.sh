#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# Mutants of the MLO rules of sbin/gt-be98-wifi-gen (mld_ap=1): each mutant
# removes one rule; test/gt-be98-wifi-gen-test.sh must go RED on every one
# (a surviving mutant is a rule no test holds). No device, no root.
#   sh test/gt-be98-wifi-gen-mlo-mutants.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
src=$here/..
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
killed=0 survived=0
mutant() {	# name sed-expression: the expression must change the generator
	rm -rf "$T/p"; mkdir -p "$T/p/src/sbin" "$T/p/test"
	cp -R "$src/src/." "$T/p/src/"; cp "$here/gt-be98-wifi-gen-test.sh" "$T/p/test/"
	sed "$2" "$src/src/sbin/gt-be98-wifi-gen" > "$T/p/src/sbin/gt-be98-wifi-gen"
	if cmp -s "$src/src/sbin/gt-be98-wifi-gen" "$T/p/src/sbin/gt-be98-wifi-gen"; then
		echo "BAD  $1: the expression changed nothing"; survived=$((survived + 1)); return
	fi
	if sh "$T/p/test/gt-be98-wifi-gen-test.sh" > "$T/log" 2>&1; then
		echo "SURVIVED $1"; survived=$((survived + 1))
	else
		echo "killed   $1 ($(grep -c '^FAIL' "$T/log") FAIL)"; killed=$((killed + 1))
	fi
}
mutant "no SAE-only rule" 's/	if (sec\[i\] != "sae") { nerrf(i, tag ": mld_ap=1 needs security=sae/	if (0) { nerrf(i, tag ": mld_ap=1 needs security=sae/'
mutant "no MLO-build rule" 's/	if (!mlocap) { nerrf/	if (0) { nerrf/'
mutant "no 2.4 GHz network rule" 's/	if (!n) nerrf(i, tag ": mld_ap=1 needs a Wi-Fi network on 2.4 GHz/	if (0) nerrf(i, tag ": mld_ap=1 needs a Wi-Fi network on 2.4 GHz/'
mutant "no weather-block rule" 's/		if (BHI >= 120 \&\& BLO <= 128) { nerrf(i, tag ": mld_ap=1 refused with radio 5gh channel/		if (0) { nerrf(i, tag ": mld_ap=1 refused with radio 5gh channel/'
mutant "no ACS rule" 's/		if (racs\[b\]) { nerrf(i, tag ": mld_ap=1 refused with radio/		if (0) { nerrf(i, tag ": mld_ap=1 refused with radio/'
mutant "no zero-wait rule" 's/	if (rzw\["5gh"\]) { nerrf/	if (0) { nerrf/'
mutant "no one-MLD rule" 's/		if (nml++) err(/		if (0) err(/'
mutant "the link H2E line" 's/print "sae_pwe=" ((b == "6g" || mlk\[i\]) ? 1 : 2) > f/print "sae_pwe=" (b == "6g" ? 1 : 2) > f/'
mutant "rnr on the link" 's/if (rnr \&\& b != "6g" \&\& !bh\[i\] \&\& !mlk\[i\]) print "rnr=1" > f/if (rnr \&\& b != "6g" \&\& !bh[i]) print "rnr=1" > f/'
mutant "no mld plan line" 's/	if (mldk \&\& (MLDID in onradio)) print "mld mld0 "/	if (0) print "mld mld0 "/'
mutant "the link without mld_addr" 's/print "mld_ap=1" > f; print "mld_addr=" bssid("6g", mi\["6g", id\]) > f/print "mld_ap=1" > f/'
mutant "(b) instead of (c) (q469 r44 SS FAIL)" 's/^function mldprimary() { return "hidden" }$/function mldprimary() { return "own" }/'
mutant "no placeholder primary" 's/				if (m) continue$/				continue/'
echo "gt-be98-wifi-gen MLO mutants: $killed killed, $survived survived"
[ $survived = 0 ]

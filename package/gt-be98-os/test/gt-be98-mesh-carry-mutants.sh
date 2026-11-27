#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# Mutants of the mesh leaf's carry= rules (lane sta4addr 11-27, MESH G-B1: a
# VLAN with no SSID crosses the leaf's trunk). Each mutant removes or bends one
# rule of sbin/gt-be98-wifi-gen (killed by test/gt-be98-wifi-gen-test.sh) or of
# init.d/gt-be98-wifi (killed by test/gt-be98-wifi-service-test.sh, run with
# SVC=<the mutant>); a surviving mutant is a rule no test holds. No device, no root.
#   sh test/gt-be98-mesh-carry-mutants.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
src=$here/..
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
killed=0 survived=0
mutant() {	# name sed-expression (the generator)
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
mutant_svc() {	# name sed-expression (the service)
	sed "$2" "$src/src/init.d/gt-be98-wifi" > "$T/svc"
	if cmp -s "$src/src/init.d/gt-be98-wifi" "$T/svc"; then
		echo "BAD  $1: the expression changed nothing"; survived=$((survived + 1)); return
	fi
	if SVC="$T/svc" sh "$here/gt-be98-wifi-service-test.sh" > "$T/log" 2>&1; then
		echo "SURVIVED $1"; survived=$((survived + 1))
	else
		echo "killed   $1 ($(grep -c '^FAIL' "$T/log") FAIL)"; killed=$((killed + 1))
	fi
}
mutant "carry= without trunk=1 accepted" 's/			if (!sttrunk) err(tag ": carry= needs trunk=1/			if (0) err(tag ": carry= needs trunk=1/'
mutant "no VLAN range check" 's/if (!isnum(ct\[j\]) || ct\[j\] + 0 < 2 || ct\[j\] + 0 > 4094)/if (!isnum(ct[j]))/'
mutant "a VLAN listed twice accepted" 's/				if ((ct\[j\] + 0) in cseen) {/				if (0) {/'
mutant "carry VIDs not on the trunk" 's/tvseen\[carryv\[j\]\] = 1; tv = tv (tv == "" ? "" : ",") carryv\[j\]/tvseen[carryv[j]] = 1/'
mutant "no carry plan line" 's/				print "carry " carryv\[j\] " " cbr\[carryv\[j\]\] > plan/				cbr[carryv[j]] = cbr[carryv[j]]/'
mutant "the -L object's bridge ignored" 's/cbr\[carryv\[j\]\] = (carryv\[j\] in objbr) ? objbr\[carryv\[j\]\] : /cbr[carryv[j]] = /'
mutant "a VID an SSID already carries gets a carry line too" 's/for (j = 1; j <= ncarry; j++) if (!(carryv\[j\] in tvseen)) {/for (j = 1; j <= ncarry; j++) {/'
mutant "management never on a carry VLAN" 's/			if (!mgi) for (j = 1; j <= ncarry; j++) if (stmgmt == "" || carryv\[j\] == stmgmt + 0) { mgc = carryv\[j\]; break }/			mgc = 0/'
mutant "the plan rewrite drops carry lines" 's/	bhtrunk|bhmgmt|carry) echo/	bhtrunk|bhmgmt) echo/'
mutant "no feature mesh_carry" 's/^	feature mesh_carry 1$/	feature mesh_carry 0/'
mutant_svc "the service ignores carry lines" 's/^		carry)	case " $net_br "/		carry_ignored)	case " $net_br "/'
echo "mesh carry= mutants: $killed killed, $survived survived"
[ $survived = 0 ]

#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# Mutation check of test/gt-be98-rfscan-test.sh: each mutant (one rule of
# sbin/gt-be98-rfscan broken on a copy of the package) must turn the suite
# RED; the unmutated copy must be GREEN (the control).
#   sh test/gt-be98-rfscan-mutants.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
pass=0 fail=0
command -v python3 > /dev/null 2>&1 || { echo "REFUSED: the suite's JSON checks need python3 (the mutants would survive unseen)"; exit 3; }
# <label> <sed expression>
mutant() {
	rm -rf "$T/p"; mkdir -p "$T/p"; cp -r "$here/../src" "$here/../test" "$T/p/"
	if [ -n "$2" ]; then
		cp "$T/p/src/sbin/gt-be98-rfscan" "$T/orig"
		sed -i "$2" "$T/p/src/sbin/gt-be98-rfscan"
		if cmp -s "$T/orig" "$T/p/src/sbin/gt-be98-rfscan"; then echo "FAIL mutant '$1': the sed changed nothing (stale mutant)"; fail=$((fail + 1)); return; fi
	fi
	timeout 300 sh "$T/p/test/gt-be98-rfscan-test.sh" > "$T/out" 2>&1; r=$?
	if [ -z "$2" ]; then
		if [ $r = 0 ]; then pass=$((pass + 1)); echo "ok   control: the suite is green on the unmutated copy"
		else fail=$((fail + 1)); echo "FAIL control: the suite is red on the unmutated copy"; grep FAIL "$T/out" | head -5; fi
		return
	fi
	if [ $r != 0 ]; then pass=$((pass + 1)); echo "ok   mutant killed: $1 ($(grep -c '^FAIL' "$T/out") failing checks)"
	else fail=$((fail + 1)); echo "FAIL mutant SURVIVED: $1"; fi
}
mutant "control" ""
mutant "our own BSSIDs kept as neighbours" 's/{ if (!(\$1 in own)) r\[\$1\] = \$0 }/{ r[$1] = $0 }/'
mutant "every window cumulative (no delta)" 's/if (T + 0 > q\[4\] + 0) {/if (0) {/'
mutant "a reset read as a delta" 's/function dd(c, p) { if (c == "-" || p == "-" || c + 0 < p + 0) return "-"; return c - p }/function dd(c, p) { if (c == "-" || p == "-") return "-"; return c - p }/'
mutant "our own block scored on every piece" 's/if (mine \&\& f != p) continue/if (0) continue/'
mutant "our own traffic counted as interference" 's/if (mine \&\& WX\[f\] != "-" \&\& WS\[f\] != "-") b = b - WX\[f\] - WS\[f\]/if (0) b = b/'
mutant "6 GHz: every channel scanned, not the PSCs" 's/b == "6g" \&\& (\$2 - 5) % 16 != 0 \&\& \$1 != of { next }/0 { next }/'
mutant "NOP channels scanned" 's/\$5 == "unavailable" { next }/0 { next }/'
mutant "no neighbour ageing" 's/now - \$7 <= ttl/1/'
mutant "the traffic gate off" 's/if \[ "\$kbps" -gt "\$BG_MAX_KBPS" \] \&\& \[ "\$sk" -lt "\$BG_MAX_SKIP" \]; then/if false; then/'
mutant "the gate never gives up (no forced step)" 's/\[ "\$sk" -lt "\$BG_MAX_SKIP" \]/true/'
mutant "the lock ignored" 's/lock_band "\$b" || { meta_set "\$b" scan_state busy; render "\$b" "\$d"; exit 0; }/lock_band "$b" || :/'
mutant "the margin ignored (any better block is a move)" 's/if (bs >= cs || gain \* 100 < margin || cs - bs < 0.05) {/if (bs >= cs) {/'
mutant "VHT 80 read as 40" 's/} else { w = 80; c = cf(vs1) }/} else { w = 40; c = cf(vs1) }/'
mutant "EHT width ignored" 's/if (ew > 0) { w = ew;/if (0) { w = ew;/'
mutant "a radar block not flagged" 's/if (RAD\[g\]) { rd++;/if (0) { rd++;/'
mutant "the noise term dropped" 's/: -95) + 100) \/ 30)$/: -95) + 100) \/ 30) * 0/'
mutant "a channel absent from one dump loses its record" 's/for (g in pc) if (!(g in seen) \&\& !(g in nd)) print pc\[g\] > out/;/'
echo "$pass passed, $fail failed"
[ $fail = 0 ]

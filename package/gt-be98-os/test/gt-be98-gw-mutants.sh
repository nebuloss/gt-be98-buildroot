#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# Mutation check of the gateway-network tests: each mutant (one rule of
# gt-be98-gw, gt-be98-l2, gt-be98-netguard or gt-be98-fwd broken on a copy
# of the package) must turn its suite RED; the unmutated copy must be GREEN
# (the control). sh test/gt-be98-gw-mutants.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
pass=0 fail=0
# <label> <file under src/> <sed expression> <test>
mutant() {
	rm -rf "$T/p"; mkdir -p "$T/p"; cp -r "$here/../src" "$here/../test" "$here/../gt-be98-os.mk" "$T/p/"
	if [ -n "$2" ]; then
		cp "$T/p/src/$2" "$T/orig"
		sed -i "$3" "$T/p/src/$2"
		if cmp -s "$T/orig" "$T/p/src/$2"; then echo "FAIL mutant '$1': the sed changed nothing (stale mutant)"; fail=$((fail + 1)); return; fi
	fi
	timeout 600 sh "$T/p/test/$4" > "$T/out" 2>&1; r=$?
	if [ -z "$2" ]; then
		if [ $r = 0 ]; then pass=$((pass + 1)); echo "ok   control: $4 green on the unmutated copy"
		else fail=$((fail + 1)); echo "FAIL control: $4 red on the unmutated copy"; grep FAIL "$T/out" | head -5; fi
		return
	fi
	if [ $r != 0 ]; then pass=$((pass + 1)); echo "ok   mutant killed: $1 ($(grep -c '^FAIL' "$T/out") failing checks in $4)"
	else fail=$((fail + 1)); echo "FAIL mutant SURVIVED: $1 ($4 still green)"; fi
}
mutant "control" "" "" gt-be98-gw-test.sh
mutant "control" "" "" gt-be98-l2-test.sh
mutant "control" "" "" gt-be98-netguard-test.sh
mutant "l2: mode=gateway read as vlan" sbin/gt-be98-l2 's/\[ "\$m" = gateway \] && { MODE=gateway; break; }/[ "$m" = nothing ] \&\& { MODE=gateway; break; }/' gt-be98-l2-test.sh
mutant "l2: the hold of gt-be98-gw ignored" sbin/gt-be98-l2 's/\[ -e "\$GW_HOLD\/\$2" \] && { MODE=gateway; return 0; }/:/' gt-be98-l2-test.sh
mutant "l2: a mode switch takes the VLAN-change path (evicts the members)" sbin/gt-be98-l2 's/if \[ "\$S_UPLINK.\$S_VID" != "\$s" \]; then/if [ "$S_TRUNK.$S_VID" != "$s" ]; then/' gt-be98-l2-test.sh
mutant "l2: sync never removes a trunk VLAN" sbin/gt-be98-l2 's/if \[ "\$MODE" = gateway \] && \[ "\$S_TRUNK" != - \]; then$/if false; then/' gt-be98-l2-test.sh
mutant "netguard: rule 6 off" sbin/gt-be98-netguard 's/if protected "\${1%%.\*}" && gw_trunk_vlan "\$1"; then/if false; then/' gt-be98-netguard-test.sh
mutant "netguard: a gateway bridge's jacks refused (trunk - not accepted)" sbin/gt-be98-netguard 's/\[ "\$L2T" = - \] && \[ "\${L2U:-\$TRUNK}" = "\$TRUNK" \]/false/' gt-be98-netguard-test.sh
mutant "gw: a public subnet accepted" sbin/gt-be98-gw 's/{ echo "subnet .\$1.: not a private (RFC 1918) range (D-GW9)"; return; }/:/' gt-be98-gw-test.sh
mutant "gw: /8 accepted" sbin/gt-be98-gw 's/\[ "\$l" -ge 16 \] && \[ "\$l" -le 30 \]/[ "$l" -ge 8 ] \&\& [ "$l" -le 30 ]/' gt-be98-gw-test.sh
mutant "gw: no isolate drop" sbin/gt-be98-gw 's/^\t\t\tiifname @iso counter drop$//' gt-be98-gw-test.sh
mutant "gw: no suppress_prefixlength rule" sbin/gt-be98-gw 's/lookup main suppress_prefixlength 0/lookup main/' gt-be98-gw-test.sh
mutant "gw: no hold for gt-be98-l2" sbin/gt-be98-gw 's/^\t\t\t\t\t: > "\$GW\/hold\/\$b"$/\t\t\t\t\t:/' gt-be98-gw-test.sh
mutant "gw: isolate narrowing deletes no conntrack" sbin/gt-be98-gw 's/ISO_NARROW="\${ISO_NARROW:-} \$id"/:/' gt-be98-gw-test.sh
mutant "gw: the WAN clash ignored" sbin/gt-be98-gw 's/{ N_LOCAL="the WAN address \$c (\$WAN_IF) is inside \$N_SUB"; break; }/:/' gt-be98-gw-test.sh
mutant "gw: the address before the rule set" sbin/gt-be98-gw 's/nft_apply "\$WAN_IF" || { rc=1; START=; stop_all_active; }/:/' gt-be98-gw-test.sh
mutant "gw: router mode not excluded" sbin/gt-be98-gw 's/router_refused=1$/router_refused=/' gt-be98-gw-test.sh
mutant "gw: the cap off" sbin/gt-be98-gw 's/\[ \$n -le \$GW_MAX \] ||/true ||/' gt-be98-gw-test.sh
mutant "fwd: the last release leaves forwarding on" sbin/gt-be98-fwd 's/fwd_set "\$BASE"/:/' gt-be98-gw-test.sh
echo "gt-be98-gw-mutants: $pass ok, $fail failed"
[ $fail -eq 0 ]

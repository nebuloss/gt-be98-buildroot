#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# Mutation check of the network-object tests (owner 11-23: a network has its
# own bridge, 0..N SSIDs and 0..N ports): each mutant (one rule of
# gt-be98-net, gt-be98-wifi-gen, gt-be98-wifi, gt-be98-netguard, gt-be98-lan
# or gt-be98-gw broken on a copy of the package) must turn its suite RED; the
# unmutated copy must be GREEN (the control). sh test/gt-be98-net-mutants.sh
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
	timeout 900 sh "$T/p/test/$4" > "$T/out" 2>&1; r=$?
	if [ -z "$2" ]; then
		if [ $r = 0 ]; then pass=$((pass + 1)); echo "ok   control: $4 green on the unmutated copy"
		else fail=$((fail + 1)); echo "FAIL control: $4 red on the unmutated copy"; grep FAIL "$T/out" | head -5; fi
		return
	fi
	if [ $r != 0 ]; then pass=$((pass + 1)); echo "ok   mutant killed: $1 ($(grep -c '^FAIL' "$T/out") failing checks in $4)"
	else fail=$((fail + 1)); echo "FAIL mutant SURVIVED: $1 ($4 still green)"; fi
}
for t in gt-be98-net-test.sh gt-be98-addr-test.sh gt-be98-wifi-gen-test.sh gt-be98-wifi-service-test.sh gt-be98-netguard-test.sh gt-be98-lan-test.sh gt-be98-gw-test.sh; do
	mutant "control" "" "" "$t"
done
# gt-be98-net: the network object
mutant "net: VLAN 1 (Default) bridged" sbin/gt-be98-net 's/\[ "\$N_VID" != 1 \] || { N_WHY=/[ "$N_VID" != 1 ] || [ 1 ] || { N_WHY=/' gt-be98-net-test.sh
mutant "net: a VLAN listed twice accepted" sbin/gt-be98-net 's/\*" \$N_VID "\*) N_WHY="VLAN \$N_VID is another/*" nothing "*) N_WHY="VLAN $N_VID is another/' gt-be98-net-test.sh
mutant "net: a network that left the list keeps its bridge" sbin/gt-be98-net 's/\[ "\$(st_get "\$id" state)" = up \] && { net_stop "\$id"; log "network \$id: gone/false \&\& { net_stop "$id"; log "network $id: gone/' gt-be98-net-test.sh
mutant "net: a mesh leaf bridges its own networks" sbin/gt-be98-net "s/grep -q '^bhtrunk ' \"\$WIFI_PLAN\" 2>\/dev\/null \&\& leaf=1/:/" gt-be98-net-test.sh
mutant "net: a VLAN move not followed by the LAN" sbin/gt-be98-net 's/MOVED="\$MOVED \$id"/:/' gt-be98-net-test.sh
mutant "net: -n ignored (follows anyway)" sbin/gt-be98-net 's/\[ "\${NOFOLLOW:-0}" != 1 \] && //' gt-be98-net-test.sh
mutant "net: the trunk always rnr0" sbin/gt-be98-net 's/^\tTRUNK=\$(trunk)$/\tTRUNK=rnr0/' gt-be98-net-test.sh
mutant "net: stop lets nothing go" sbin/gt-be98-net 's/\[ "\$(st_get "\$id" state)" = up \] && net_stop "\$id"$/:/' gt-be98-net-test.sh
# gt-be98-wifi-gen: N SSIDs -> one bridge
mutant "wifi-gen: one SSID per VLAN again" sbin/gt-be98-wifi-gen 's/^\t\t# several SSIDs on one VLAN share the bridge of its network (header:$/\t\telse if (vlan[i] in vseen) nerrf(i, tag ": vlan " vlan[i] " also used by network " vseen[vlan[i]]); else vseen[vlan[i]] = id\n&/' gt-be98-wifi-gen-test.sh
mutant "wifi-gen: every SSID its own bridge" sbin/gt-be98-wifi-gen 's/^\t\telse if (bv in vfirst) nbr\[i\] = vfirst\[bv\]$/\t\telse if (0) nbr[i] = vfirst[bv]/' gt-be98-wifi-gen-test.sh
mutant "wifi-gen: -L ignored" sbin/gt-be98-wifi-gen 's/^\t\tif (bv in objbr) nbr\[i\] = objbr\[bv\]$/\t\tif (0) nbr[i] = objbr[bv]/' gt-be98-wifi-gen-test.sh
mutant "wifi-gen: the last -L line of a VLAN wins" sbin/gt-be98-wifi-gen 's/if (!((ov + 0) in objbr)) objbr\[ov + 0\]/objbr[ov + 0]/' gt-be98-wifi-gen-test.sh
mutant "wifi-gen: a skipped SSID keeps the bridge name" sbin/gt-be98-wifi-gen 's/if (bh\[i\] || rep\[i\] || rtd\[i\] != "" || (i in bad) || !isnum(vlan\[i\])) continue/if (bh[i] || rep[i] || rtd[i] != "" || !isnum(vlan[i])) continue/' gt-be98-wifi-gen-test.sh
mutant "wifi-gen: no shared_vlan feature" sbin/gt-be98-wifi-gen 's/^\tfeature shared_vlan 1$/\tfeature shared_vlan 0/' gt-be98-wifi-gen-test.sh
# gt-be98-wifi: one bridge listed once, isolation per SSID
mutant "wifi: a shared bridge listed twice" init.d/gt-be98-wifi 's/net)\tcase " \$net_br " in \*" \$b "\*) ;; \*) net_br=/net)\tcase " $net_br " in *" nothing "*) ;; *) net_br=/' gt-be98-wifi-service-test.sh
mutant "wifi: a mixed bridge isolated whole" init.d/gt-be98-wifi 's/case " \$net_opn " in \*" \$b "\*) mixed="\$mixed \$b" ;; \*) net_iso=/case " $net_opn " in *" nothing "*) mixed="$mixed $b" ;; *) net_iso=/' gt-be98-wifi-service-test.sh
mutant "wifi: no -L to the generator" init.d/gt-be98-wifi 's/-L "\$NETWORKS_FILE" \$cc -S/$cc -S/' gt-be98-wifi-service-test.sh
# gt-be98-netguard: rule 3 per BSS
mutant "netguard: WIFI_ISOLATE_BSS ignored" sbin/gt-be98-netguard 's/case " \${ISOLATE_BSS:-} " in \*" \$i "\*) f=1 ;; esac ;; esac/;; esac/' gt-be98-netguard-test.sh
# gt-be98-lan: the network's own bridge first
mutant "lan: the SSID's bridge before the network's" init.d/gt-be98-lan 's/^lan_net_list() { lan_nets_file; lan_net_wifi; }$/lan_net_list() { lan_net_wifi; lan_nets_file; }/' gt-be98-lan-test.sh
# gt-be98-gw: the networks' bridges before the addresses
mutant "gw: apply does not run gt-be98-net" sbin/gt-be98-gw 's/^apply)\t\[ -x "\$NET" \] && "\$NET" apply -n > \/dev\/null$/apply)\t:/' gt-be98-gw-test.sh
# gt-be98-addr: the box's addresses and the management filter
mutant "addr: the management not dropped elsewhere" sbin/gt-be98-addr 's/^\techo "\t\ttcp dport { \$MGMT_PORTS } counter drop"$/\t:/' gt-be98-addr-test.sh
mutant "addr: the USB lifeline not always in (lock-out)" sbin/gt-be98-addr 's/^\techo "\t\tiifname \\"usb\*\\" accept"$/\t:/' gt-be98-addr-test.sh
mutant "addr: a gateway network takes an address" sbin/gt-be98-addr 's/\[ "\$NMODE" != gateway \] ||/[ 1 ] ||/' gt-be98-addr-test.sh
mutant "addr: a static overlapping another network's accepted" sbin/gt-be98-addr 's/\&\& { A_WHY="\$A_CIDR overlaps a static address/\&\& false \&\& { A_WHY="$A_CIDR overlaps a static address/' gt-be98-addr-test.sh
mutant "addr: a second DHCP address on one network accepted" sbin/gt-be98-addr 's/\*" \$A_NET "\*) A_WHY="network \$A_NET has a DHCP address already/*" nothing "*) A_WHY="network $A_NET has a DHCP address already/' gt-be98-addr-test.sh
mutant "addr: one IP twice accepted" sbin/gt-be98-addr 's/\*" \${A_CIDR%\/\*} "\*) A_WHY=/*" nothing "*) A_WHY=/' gt-be98-addr-test.sh
mutant "addr: secondaries of one network refused as overlaps" sbin/gt-be98-addr 's/^\t\t\t\[ "\$3" = "\$A_NET" \] \&\& continue$/\t\t\t:/' gt-be98-addr-test.sh
mutant "addr: a static on Default accepted" sbin/gt-be98-addr 's/static)\t\[ "\$NV" != 1 \] ||/static)\t[ 1 ] ||/' gt-be98-addr-test.sh
mutant "addr: the broadcast address accepted" sbin/gt-be98-addr 's/\&\& \[ \$(( (n | ~m) \& 0xffffffff )) != "\$n" \]//' gt-be98-addr-test.sh
mutant "addr: a removed DHCP address keeps its client" sbin/gt-be98-addr 's/\tdhcp)\t\[ "\$d" = "\$MGMT_DEV" \] || dhcp_stop "\$d" ;;/\tdhcp) : ;;/' gt-be98-addr-test.sh
mutant "addr: a filter without a list (the image default broken)" sbin/gt-be98-addr 's/^\tif \[ -s "\$AD\/listed" \]; then$/\tif true; then/' gt-be98-addr-test.sh
mutant "addr: the lease's router not routed" sbin/gt-be98-addr 's/\[ -z "\$gw" \] || ip route replace default via "\$gw" dev "\$d" metric "\$ADDR_METRIC"/:/' gt-be98-addr-test.sh
mutant "addr: the gateway mgmt bridges left out of the filter" sbin/gt-be98-addr "s/\[ -x \"\\\$GWT\" \] \&\& /false \&\& /" gt-be98-addr-test.sh
echo "gt-be98-net-mutants: $pass ok, $fail failed"
[ $fail -eq 0 ]

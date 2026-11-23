#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# Offline test of sbin/gt-be98-addr, the box's own addresses (owner 11-23:
# static or DHCP per network, the management reachable on them only):
#   sh test/gt-be98-addr-test.sh
# Fakes: ip (addresses and routes kept in files, every call logged), nft
# (logs, keeps the last file; -c with REFUSE in it fails), start-stop-daemon
# (records the dhcpcd command line, writes a live pid), gt-be98-net bridge,
# gt-be98-gw mgmt-addrs. Every check has a control that differs in one input.
set -u
here=$(cd "$(dirname "$0")" && pwd)
AT="$here/../src/sbin/gt-be98-addr"
T=$(mktemp -d)
trap 'for f in "$T"/run/gt-be98-addr/*.dhcp.pid; do [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null; done; rm -rf "$T"' EXIT
export FAKE="$T" GT_BE98_RUN="$T/run" GT_BE98_ADDRESSES="$T/addresses.conf" GT_BE98_NETWORKS="$T/networks.conf" \
	GT_BE98_NET="$T/bin/net" GT_BE98_GW="$T/bin/gw" GT_BE98_SYSNET="$T/sys" GT_BE98_DHCPCD=/sbin/dhcpcd
mkdir -p "$T/bin" "$T/run" "$T/sys/rnr0" "$T/sys/brwifi100003" "$T/sys/brwifi100005"
: > "$T/addrs"; : > "$T/routes"
cat > "$T/bin/ip" <<'X'
#!/bin/sh
echo "ip $*" >> "$FAKE/log"
case "$*" in
"addr replace "*)	grep -vx "$5 $3" "$FAKE/addrs" > "$FAKE/a.new"; echo "$5 $3" >> "$FAKE/a.new"; mv "$FAKE/a.new" "$FAKE/addrs" ;;
"addr del "*)	grep -vx "$5 $3" "$FAKE/addrs" > "$FAKE/a.new"; mv "$FAKE/a.new" "$FAKE/addrs" ;;
"route replace default via "*)	grep -v " $7 " "$FAKE/routes" > "$FAKE/r.new"; echo "default $5 $7 $9" >> "$FAKE/r.new"; mv "$FAKE/r.new" "$FAKE/routes" ;;
"route del default dev "*)	grep -v " $5 " "$FAKE/routes" > "$FAKE/r.new"; mv "$FAKE/r.new" "$FAKE/routes" ;;
"-4 -o addr show dev "*)	while read -r d c; do [ "$d" = "$6" ] && echo "1: $d    inet $c scope global $d"; done < "$FAKE/addrs" ;;
esac
exit 0
X
cat > "$T/bin/nft" <<'X'
#!/bin/sh
echo "nft $*" >> "$FAKE/log"
case "$1" in -c) grep -q REFUSE "$3" && exit 1; cp "$3" "$FAKE/last.nft" ;; esac
exit 0
X
# start: a live sleeper's pid in the pid file; stop: kill it
cat > "$T/bin/start-stop-daemon" <<'X'
#!/bin/sh
echo "ssd $*" >> "$FAKE/log"
op=$1; pf=
while [ $# -gt 0 ]; do [ "$1" = --pidfile ] && pf=$2; shift; done
case "$op" in
--start) sleep 300 & echo $! > "$pf" ;;
--stop) kill "$(cat "$pf")" 2>/dev/null ;;
esac
exit 0
X
printf '#!/bin/sh\n[ "$1" = bridge ] || exit 2\ncase "$2" in 930) echo brwifi100003 ;; 950) echo brwifi100005 ;; 960) echo brwifi100006 ;; *) exit 1 ;; esac\n' > "$T/bin/net"
printf '#!/bin/sh\n[ "$1" = mgmt-addrs ] && cat "$FAKE/gwmgmt" 2>/dev/null\nexit 0\n' > "$T/bin/gw"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/logger"
chmod +x "$T/bin/"*
PATH="$T/bin:$PATH"
pass=0 fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   $1"; else fail=$((fail + 1)); echo "FAIL $1: want [$2] got [$3]"; fi; }
A() { : > "$T/log"; sh "$AT" "$@" 2>> "$T/err"; }
st() { sh "$AT" status | awk -v i="$1" '$2 == i { print $6 }'; }	# by ADDRESS id
cat > "$T/networks.conf" <<'X'
network=1 name=Default vlan=1 subnet= mode=vlan isolate=0 mgmt=1
network=3 name=Lab vlan=930 subnet= mode=vlan isolate=0 mgmt=1
network=4 name=Gw vlan=940 subnet=192.168.40.1/24 mode=gateway isolate=0 mgmt=1
network=5 name=Iot vlan=950 subnet= mode=vlan isolate=0 mgmt=1
network=6 name=Later vlan=960 subnet= mode=vlan isolate=0 mgmt=1
X

# 1. no list: a clean no-op (the image's management, no filter)
A apply; check "no list: rc 0, no ip/nft call, no filter" "0 0" "$? $(grep -c '^ip \|^nft ' "$T/log")"
check "features" "features addresses" "$(sh "$AT" features)"
# 2. a static address and a DHCP one; Default by DHCP (the image's client); refusals
# address ids: 13 = network 3 static, 15 = network 5 DHCP, 11 = Default, 14 =
# a gateway network, 19 = no such network, 13 twice, 16 = no bridge yet, 23 =
# a second static on network 3 (a secondary), 25 = a second DHCP on network 5
cat > "$T/addresses.conf" <<'X'
# the box's addresses
address=13 network=3 mode=static cidr=192.168.30.2/24 gateway=192.168.30.1
mode=dhcp network=5 address=15
address=11 network=1 mode=dhcp
address=14 network=4 mode=dhcp
address=19 network=9 mode=dhcp
address=13 network=3 mode=dhcp
address=16 network=6 mode=dhcp
address=23 network=3 mode=static cidr=192.168.31.2/24
address=25 network=5 mode=dhcp
X
A apply; check "apply: rc 0" 0 $?
check "static on brwifi100003 with its default route (metric 2600), and its secondary" "brwifi100003 192.168.30.2/24|brwifi100003 192.168.31.2/24|default 192.168.30.1 brwifi100003 2600|" "$(tr '\n' '|' < "$T/addrs")$(tr '\n' '|' < "$T/routes")"
check "DHCP on brwifi100005: its own dhcpcd (private namespace, our script)" yes \
	"$(grep -q 'ssd --start --background --make-pidfile --pidfile .*brwifi100005.dhcp.pid --exec /usr/bin/unshare' "$T/log" && grep -qx 'allowinterfaces brwifi100005' "$T/run/gt-be98-addr/brwifi100005.dhcpcd.conf" && echo yes || echo no)"
check "Default (VLAN 1) by DHCP: up on rnr0, no second client" "up 0" "$(st 11) $(grep -c 'pidfile .*rnr0.dhcp.pid' "$T/log")"
check "refused: a gateway network (14), a network not listed (19), a 2nd DHCP on one network (25)" "refused refused refused" "$(st 14) $(st 19) $(st 25)"
check "an address id listed twice: the first line wins (13 stays static)" "static" "$(sh "$AT" status | awk '$2 == 13 { print $3 }')"
check "a network without its bridge yet (16): waiting; status names the network" "waiting network=6" "$(st 16) $(sh "$AT" status | awk '$2 == 16 { print $7 }')"
f=$T/last.nft
check "the filter: admin/SSH in on the listed networks' devices only, lo / USB / bhm0 always, dropped elsewhere" \
	'iifname "lo" accept|iifname "usb*" accept|iifname "enx*" accept|iifname "bhm0" accept|iifname { "brwifi100003", "brwifi100005", "brwifi100006", "rnr0" } tcp dport { 22, 80, 443 } accept|tcp dport { 22, 80, 443 } counter drop|' \
	"$(grep -E 'iifname|dport' "$f" | sed 's/^[[:space:]]*//' | tr '\n' '|')"
# 3. the addresses in force (the web UI's listener): static, a lease, Default's own
echo "rnr0 10.9.0.5/24" >> "$T/addrs"
check "addrs: before any lease, the statics + Default's (by address id)" "addr 11 inet 10.9.0.5 rnr0|addr 13 inet 192.168.30.2 brwifi100003|addr 23 inet 192.168.31.2 brwifi100003|" "$(sh "$AT" addrs | sort | tr '\n' '|')"
interface=brwifi100005 reason=BOUND new_ip_address=10.50.0.7 new_subnet_cidr=24 new_routers=10.50.0.1 sh "$AT"
check "DHCP lease (the script): recorded, its router at metric 2600" "addr 15 inet 10.50.0.7 brwifi100005 yes" \
	"$(sh "$AT" addrs | grep '^addr 15 ') $(grep -q 'default 10.50.0.1 brwifi100005 2600' "$T/routes" && echo yes || echo no)"
interface=brwifi100005 reason=EXPIRE sh "$AT"
check "lease lost: no address listed, route gone" "0 no" "$(sh "$AT" addrs | grep -c '^addr 15 ') $(grep -q brwifi100005 "$T/routes" && echo yes || echo no)"
interface=rnr0 reason=BOUND new_ip_address=1.2.3.4 new_subnet_cidr=24 sh "$AT"
check "control: an event for a device it does not run is ignored" "" "$(cat "$T/run/gt-be98-addr/rnr0.lease" 2>/dev/null)"
# 4. the gateway networks' management (mgmt-addrs) are in the filter too
echo "mgmt 4 inet 192.168.40.1 brwifi100004" > "$T/gwmgmt"
A apply; check "a gateway network with mgmt=1: its bridge in the filter" yes "$(grep -q '"brwifi100004"' "$f" && echo yes || echo no)"
rm -f "$T/gwmgmt"
# 5. a change: the static address moves; then removed from the list; then no list at all
sed -i 's#cidr=192.168.30.2/24 gateway=192.168.30.1#cidr=192.168.30.3/24#' "$T/addresses.conf"
A apply; check "static changed: the old address gone, the new one set, the route gone, the secondary kept" "brwifi100003 192.168.30.3/24|brwifi100003 192.168.31.2/24|" "$(grep brwifi100003 "$T/addrs" | sort | tr '\n' '|')$(grep brwifi100003 "$T/routes")"
sed -i '/ network=3 /d; /^mode=dhcp network=5/d' "$T/addresses.conf"
p=$(cat "$T/run/gt-be98-addr/brwifi100005.dhcp.pid")
A apply; check "removed from the list: static deleted, the DHCP client stopped, both forgotten" "no no no" \
	"$(grep -q brwifi100003 "$T/addrs" && echo yes || echo no) $(kill -0 "$p" 2>/dev/null && echo yes || echo no) $(sh "$AT" status | grep -cE '^addr (13|15|23) ' | sed 's/^0$/no/')"
check "... Default's untagged address never touched" "rnr0 10.9.0.5/24" "$(grep '^rnr0 ' "$T/addrs")"
rm -f "$T/addresses.conf"
A apply; check "the list gone: the filter deleted (the image's management again)" yes "$(grep -q 'nft delete table inet gt_be98_addr' "$T/log" && echo yes || echo no)"
# 6. validation: bad CIDRs, a static on Default, overlaps
for c in 192.168.30.0/24 192.168.30.255/24 10.0.0.1/31 10.0.0.1/7 127.0.0.2/8 224.0.0.1/8 300.1.1.1/24 10.1.1.1 ""; do
	printf 'address=1 network=3 mode=static cidr=%s\n' "$c" > "$T/addresses.conf"; A apply
	check "refused static cidr [$c]" refused "$(st 1)"
done
printf 'address=1 network=3 mode=static cidr=10.3.0.9/16\n' > "$T/addresses.conf"; A apply; check "control: 10.3.0.9/16 up" up "$(st 1)"
printf 'address=1 network=3 mode=static cidr=10.3.0.9/16\naddress=2 network=5 mode=static cidr=10.3.200.1/24\n' > "$T/addresses.conf"; A apply
check "a static overlapping ANOTHER network's refused, the first kept" "up refused" "$(st 1) $(st 2)"
printf 'address=1 network=3 mode=static cidr=10.3.0.9/16\naddress=2 network=3 mode=static cidr=10.3.200.1/24\naddress=3 network=3 mode=static cidr=10.3.0.9/24\n' > "$T/addresses.conf"; A apply
check "control: the same network's secondary in its subnet up; the same IP twice refused" "up up refused" "$(st 1) $(st 2) $(st 3)"
printf 'address=1 network=1 mode=static cidr=10.9.0.9/24\n' > "$T/addresses.conf"; A apply; check "static on Default refused (DHCP only)" refused "$(st 1)"
printf 'address=1 network=5 mode=dhcp cidr=10.1.1.1/24\n' > "$T/addresses.conf"; A apply; check "dhcp with a cidr refused" refused "$(st 1)"
printf 'address=1 network=5 mode=bogus\n' > "$T/addresses.conf"; A apply; check "a bad mode refused" refused "$(st 1)"
printf 'address=0 network=5 mode=dhcp\naddress=10000 network=5 mode=dhcp\n' > "$T/addresses.conf"; A apply; check "address ids 0 and 10000 name no object" "" "$(sh "$AT" status)"
# 7. a rejected filter keeps the previous one (and says so); stop removes everything
printf 'address=1 network=3 mode=static cidr=10.3.0.9/16\naddress=2 network=1 mode=dhcp\n' > "$T/addresses.conf"; A apply; cp "$f" "$T/prev.nft"
GT_BE98_ADDR_MGMT_DEV=REFUSE A apply; check "a filter nft refuses: rc 1, the previous one kept" "1 same" "$? $(cmp -s "$f" "$T/prev.nft" && echo same || echo changed)"
A stop; check "stop: addresses removed, filter deleted, status empty" "no yes " "$(grep -q 10.3.0.9 "$T/addrs" && echo yes || echo no) $(grep -q 'nft delete table' "$T/log" && echo yes || echo no) $(sh "$AT" status)"
echo "gt-be98-addr-test: $pass ok, $fail failed"
[ $fail -eq 0 ]

#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# Offline test of sbin/gt-be98-gw (gateway networks) and sbin/gt-be98-fwd
# (the one owner of ip_forward): sh test/gt-be98-gw-test.sh
# No device, no root. Fakes: `ip` keeps the box's addresses and logs every
# call; gt-be98-l2 (list from a file, sync logged), gt-be98-wan (ifname,
# check from files), nft (logs, copies the file; a file with REFUSE is
# rejected), conntrack, dnsmasq (a sleeper writing its pid file),
# start-stop-daemon. The real gt-be98-fwd writes a fake ip_forward file.
# The generated rule sets are also checked by the kernel's parser
# (`unshare -rn nft -c -f`, with a bad-rule-set control) when available.
# Every check has a control that differs in one input.
set -u
here=$(cd "$(dirname "$0")" && pwd)
GWT="$here/../src/sbin/gt-be98-gw"
FWDT="$here/../src/sbin/gt-be98-fwd"
T=$(mktemp -d)
trap 'for f in $(find "$T" -name "*.pid" 2>/dev/null); do kill "$(cat "$f")" 2>/dev/null; done; rm -rf "$T"' EXIT
export FAKE="$T" GT_BE98_RUN="$T/run" GT_BE98_NETWORKS="$T/networks.conf" GT_BE98_L2="$T/bin/l2" \
	GT_BE98_WAN="$T/bin/wan" GT_BE98_FWD="$FWDT" GT_BE98_FWD_SYSCTL="$T/ip_forward" \
	GT_BE98_LAN_CONF="$T/lan.conf" GT_BE98_LAN_APPLIED="$T/run/gt-be98-lan.applied" \
	GT_BE98_STA_ROUTED="$T/run/sta.routed" GT_BE98_ROUTER_APPLIED="$T/run/gt-be98-router.applied" \
	GT_BE98_GW_RESOLV="$T/resolv.conf"
mkdir -p "$T/bin" "$T/run"
echo 0 > "$T/ip_forward"; : > "$T/addrs"; : > "$T/l2list"; echo rnr0 > "$T/wanif"; : > "$T/wancheck"
# ip: addresses in $FAKE/addrs ("<dev> <cidr>"), routes from route-<dev>
cat > "$T/bin/ip" <<'X'
#!/bin/sh
echo "ip $*" >> "$FAKE/log"
case "$*" in
"-4 -o addr show")	n=1; while read -r d c; do echo "$n: $d    inet $c brd 0.0.0.0 scope global $d"; n=$((n+1)); done < "$FAKE/addrs" ;;
"-4 -o addr show dev "*)	while read -r d c; do [ "$d" = "$6" ] && echo "1: $d    inet $c scope global $d"; done < "$FAKE/addrs" ;;
"addr replace "*)	[ -f "$FAKE/refuse-addr" ] && exit 2; grep -vx "$5 $3" "$FAKE/addrs" > "$FAKE/a.new"; echo "$5 $3" >> "$FAKE/a.new"; mv "$FAKE/a.new" "$FAKE/addrs" ;;
"addr del "*)	grep -vx "$5 $3" "$FAKE/addrs" > "$FAKE/a.new"; mv "$FAKE/a.new" "$FAKE/addrs" ;;
"-4 route show default dev "*)	cat "$FAKE/route-$6" 2>/dev/null ;;
esac
exit 0
X
printf '#!/bin/sh\necho "l2 $*" >> "$FAKE/log"\n[ "$1" = list ] && cat "$FAKE/l2list"\nexit 0\n' > "$T/bin/l2"
printf '#!/bin/sh\ncase "$1" in ifname) cat "$FAKE/wanif" ;; check) cat "$FAKE/wancheck" ;; esac\n' > "$T/bin/wan"
cat > "$T/bin/nft" <<'X'
#!/bin/sh
echo "nft $*" >> "$FAKE/log"
if [ "$1" = -c ]; then cp "$3" "$FAKE/last.nft"; grep -q REFUSE "$3" && exit 1; fi
exit 0
X
printf '#!/bin/sh\necho "conntrack $*" >> "$FAKE/log"\nexit 1\n' > "$T/bin/conntrack"
cat > "$T/bin/dnsmasq" <<'X'
#!/bin/sh
echo "dnsmasq $*" >> "$FAKE/log"
c=${1#--conf-file=}
sleep 1000 & echo $! > "$(sed -n 's/^pid-file=//p' "$c")"
exit 0
X
cat > "$T/bin/start-stop-daemon" <<'X'
#!/bin/sh
echo "start-stop-daemon $*" >> "$FAKE/log"
[ "$1 $2" = "--stop --pidfile" ] && kill "$(cat "$3")" 2>/dev/null
exit 0
X
printf '#!/bin/sh\nexit 0\n' > "$T/bin/logger"
chmod +x "$T/bin/"*
PATH="$T/bin:$PATH"
G=$T/run/gt-be98-gw
pass=0 fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   $1"; else fail=$((fail + 1)); echo "FAIL $1: want [$2] got [$3]"; fi; }
yn() { if "$@"; then echo yes; else echo no; fi; }
has() { grep -qF -- "$2" "$1" 2>/dev/null; }
run() { : > "$T/log"; ${SH:-sh} "$GWT" "$@" > "$T/out" 2> "$T/err"; rc=$?; }
log() { grep -E -- "$1" "$T/log" | tr '\n' '|' | sed 's/|$//'; }
st() { sed -n "s/^$2 //p" "$G/net/$1" 2>/dev/null; }
NETS() { printf '# web UI\n' > "$GT_BE98_NETWORKS"; for l; do echo "$l" >> "$GT_BE98_NETWORKS"; done; }
ex() { if [ -e "$1" ]; then echo yes; else echo no; fi; }
nftcheck() {	# the kernel's parser on a generated rule set
	command -v unshare >/dev/null 2>&1 && [ -x "${NFT:-/usr/sbin/nft}" ] || return 2
	unshare -rn "${NFT:-/usr/sbin/nft}" -c -f "$1" > "$T/nft.err" 2>&1
}

# ===== gt-be98-fwd: the one owner of ip_forward =====
F() { ${SH:-sh} "$FWDT" "$@"; }
F hold lan; check "fwd: hold lan: ip_forward 1" "1 yes" "$(cat "$T/ip_forward") $(yn F held lan)"
F hold sta; F release lan; check "fwd: release lan while sta holds: stays 1" "1 no yes" "$(cat "$T/ip_forward") $(yn F held lan) $(yn F held sta)"
F release sta; check "fwd: the last holder leaves: back to the image's 0" "0 no" "$(cat "$T/ip_forward") $(yn F held)"
F release sta; check "fwd: a release without a hold: rc 0, 0" "0 0" "$? $(cat "$T/ip_forward")"
F hold Lan 2>/dev/null; check "fwd: owner refused (not lower-case)" 2 $?
F hold lan; F hold lan; F release lan; check "fwd: hold is idempotent (one release lets go)" 0 "$(cat "$T/ip_forward")"
F hold gw; check "fwd: status" "ip_forward 1|holder gw" "$(F status | tr '\n' '|' | sed 's/|$//')"
F release gw

# ===== gt-be98-gw =====
# 1. no file, a VLAN-only line, a subnet without mode=: a clean no-op
rm -f "$GT_BE98_NETWORKS"
run apply; check "no networks file: rc 0, nothing touched (no ip addr/rule, nft, dnsmasq, l2 up)" "0 " "$rc $(log '^(ip (addr|rule)|nft|dnsmasq)')"
NETS "network=3 name=Up vlan=30 subnet=192.168.30.1/24" "network=5 name=V vlan=50 subnet=192.168.50.1/24 mode=vlan"
run apply; check "subnets without mode=gateway (D-GW1): nothing touched" "0 " "$rc $(log '^(ip (addr|rule)|nft|dnsmasq)')"
check "... ip_forward untouched" 0 "$(cat "$T/ip_forward")"
check "features" "features gateway" "$(sh "$GWT" features)"
# 2. one gateway network on its bridge (gt-be98-l2 runs it with trunk -)
NETS "network=3 name=Up vlan=30 subnet=192.168.30.1/24" "network=4 name=Lab vlan=40 subnet=192.168.40.1/24 mode=gateway isolate=0 mgmt=1"
echo "brwifi100004 - 40 lan" > "$T/l2list"
echo "default via 10.9.0.1 dev rnr0 proto dhcp" > "$T/route-rnr0"
echo "rnr0 10.9.0.50/24" >> "$T/addrs"; echo "eth0 172.31.0.5/24" >> "$T/addrs"
run apply; check "gateway network 4: rc 0, routed on brwifi100004" "0 routed brwifi100004" "$rc $(st 4 state) $(st 4 bridge)"
check "... gt-be98-l2 sync BEFORE the rule set, the rule set BEFORE the address" "l2 sync|nft -c -f $G/gw.nft.new|nft -f $G/gw.nft.new|ip addr replace 192.168.40.1/24 dev brwifi100004" \
	"$(log '^(l2 sync|nft -|ip addr replace)')"
check "... policy rules: main without its default, then table 184" \
	"ip rule add iif brwifi100004 lookup main suppress_prefixlength 0 priority 184|ip rule add iif brwifi100004 lookup 184 priority 185" "$(log '^ip rule add')"
check "... table 184: the WAN's default only" "ip route replace default via 10.9.0.1 dev rnr0 table 184" "$(log '^ip route replace')"
check "... held for gt-be98-l2 (no trunk VLAN under it)" yes "$(ex "$G/hold/brwifi100004")"
check "... forwarding held as gw" "1 yes" "$(cat "$T/ip_forward") $(yn F held gw)"
check "... the VLAN-only network 3 untouched" "" "$(log '192\.168\.30')"
N=$G/gw.nft
check "nft: gw set = the bridge, nat set = it, iso empty, mgmt = it" "yes yes yes yes" \
	"$(yn grep -A2 'set gw {' "$N" | grep -q 'elements = { brwifi100004 }' && echo yes) $(sed -n '/set nat {/,/}/p' "$N" | grep -q 'brwifi100004' && echo yes || echo no) $(sed -n '/set iso {/,/}/p' "$N" | grep -q elements && echo no || echo yes) $(sed -n '/set mgmt {/,/}/p' "$N" | grep -q brwifi100004 && echo yes || echo no)"
check "nft: masquerade of the subnet out of the WAN" yes "$(yn has "$N" 'oifname "rnr0" ip saddr { 192.168.40.0/24 } masquerade')"
check "nft: internet only for @nat, nothing else out, nothing unsolicited in" "yes yes yes" \
	"$(yn has "$N" 'iifname @nat oifname "rnr0" accept') $(yn has "$N" 'iifname @gw counter drop') $(yn has "$N" 'oifname @gw counter drop')"
check "nft: input: DHCP, DNS, ICMP always, management on @mgmt" "yes yes yes yes" \
	"$(yn has "$N" 'iifname @gw udp dport 67 accept') $(yn has "$N" 'th dport 53 accept') $(yn has "$N" 'meta l4proto icmp accept') $(yn has "$N" 'iifname @mgmt tcp dport { 22, 80, 443 } accept')"
D=$G/dnsmasq.conf
check "dnsmasq: one instance, the bridge, range .100-.199, router and DNS .1, 12h" \
	"interface=brwifi100004|dhcp-range=set:n4,192.168.40.100,192.168.40.199,255.255.255.0,12h|dhcp-option=tag:n4,option:router,192.168.40.1|dhcp-option=tag:n4,option:dns-server,192.168.40.1" \
	"$(grep -E '^(interface|dhcp-range|dhcp-option)' "$D" | tr '\n' '|' | sed 's/|$//')"
check "dnsmasq: never on rnr0, leases in /run (D-GW7), static leases file, authoritative" "yes yes yes yes" \
	"$(yn grep -qx except-interface=rnr0 "$D") $(yn grep -qx "dhcp-leasefile=$G/leases" "$D") $(yn grep -qx "dhcp-hostsfile=$G/dhcp-hosts" "$D") $(yn grep -qx dhcp-authoritative "$D")"
check "status line" "net 4 routed brwifi100004 192.168.40.1/24 isolate=0 mgmt=1 starts=1 refusals=0 why=" "$(sh "$GWT" status | grep '^net 4')"
# the kernel's parser (unshare -rn nft -c): the rule set, and a bad one
nftcheck "$N"; r=$?
if [ $r = 2 ]; then echo "SKIP nft -c: no unshare/nft here"
else
	check "nft -c (kernel parser): the one-network rule set" 0 $r; [ $r = 0 ] || cat "$T/nft.err"
	sed 's/type filter hook forward/type filter hook fwd/' "$N" > "$T/bad.nft"
	nftcheck "$T/bad.nft"; check "nft -c control: a bad rule set (hook fwd) is rejected" 1 $?
fi
# 3. the same apply again: nothing restarted
pid=$(cat "$G/dnsmasq.pid")
run apply; check "apply again: rc 0, dnsmasq not restarted, starts still 1" "0 $pid 1" "$rc $(cat "$G/dnsmasq.pid") $(st 4 starts)"
# 4. a second network, isolated (mgmt defaults to 0 when isolate=1)
NETS "network=4 name=Lab vlan=40 subnet=192.168.40.1/24 mode=gateway isolate=0 mgmt=1" "network=6 name=Guest vlan=41 subnet=10.41.0.1/16 mode=gateway isolate=1"
printf 'brwifi100004 - 40 lan\nbrwifi7 - 41 wifi\n' > "$T/l2list"
run apply; check "network 6 (isolate=1, mgmt absent): routed, mgmt 0" "0 routed 1 0" "$rc $(st 6 state) $(st 6 isolate) $(st 6 mgmt)"
check "nft: iso = brwifi7, mgmt = brwifi100004 only, gw both" "yes yes yes" \
	"$(sed -n '/set iso {/,/}/p' "$N" | grep -q 'elements = { brwifi7 }' && echo yes || echo no) $(sed -n '/set mgmt {/,/}/p' "$N" | grep -q 'elements = { brwifi100004 }' && echo yes || echo no) $(sed -n '/set gw {/,/}/p' "$N" | grep -q 'elements = { brwifi100004, brwifi7 }' && echo yes || echo no)"
check "nft: isolated drops before the inter-network accept" "yes" "$(awk '/iifname @iso counter drop/ { i = NR } /iifname @gw oifname @gw accept/ { a = NR } END { print (i && a && i < a) ? "yes" : "no" }' "$N")"
check "dnsmasq restarted with both networks, the /16 range .0.100-.0.199" "yes yes" \
	"$(yn grep -qx 'dhcp-range=set:n6,10.41.0.100,10.41.0.199,255.255.0.0,12h' "$D") $([ "$(cat "$G/dnsmasq.pid")" != "$pid" ] && echo yes || echo no)"
nftcheck "$N"; r=$?; [ $r = 2 ] || check "nft -c (kernel parser): two networks, an isolated one" 0 $r
# 5. narrowing: network 4 becomes isolated -> its flows to/from 6 deleted
NETS "network=4 name=Lab vlan=40 subnet=192.168.40.1/24 mode=gateway isolate=1 mgmt=1" "network=6 name=Guest vlan=41 subnet=10.41.0.1/16 mode=gateway isolate=1"
run apply; check "isolate 0 -> 1 on 4: conntrack 4<->6 deleted after the rule set" \
	"nft -f $G/gw.nft.new|conntrack -D -s 192.168.40.0/24 -d 10.41.0.0/16|conntrack -D -s 10.41.0.0/16 -d 192.168.40.0/24" "$(log '^(nft -f|conntrack)')"
run apply; check "control: the same isolate again deletes nothing" "" "$(log '^conntrack')"
NETS "network=4 name=Lab vlan=40 subnet=192.168.40.1/24 mode=gateway isolate=1 mgmt=0" "network=6 name=Guest vlan=41 subnet=10.41.0.1/16 mode=gateway isolate=1"
run apply; check "mgmt 1 -> 0 on 4: its management sessions deleted" \
	"conntrack -D -s 192.168.40.0/24 -p tcp --dport 22|conntrack -D -s 192.168.40.0/24 -p tcp --dport 80|conntrack -D -s 192.168.40.0/24 -p tcp --dport 443" "$(log '^conntrack')"
# 6. the WAN gets a lease inside network 4's subnet: local (NAT refused), restored after
NETS "network=4 name=Lab vlan=40 subnet=192.168.40.1/24 mode=gateway isolate=0 mgmt=1"
printf 'brwifi100004 - 40 lan\n' > "$T/l2list"
run apply
sed -i 's|^rnr0 .*|rnr0 192.168.40.77/24|' "$T/addrs"
run reroute; check "WAN inside 192.168.40.0/24: local, logged, NAT and @nat empty, flows deleted" "0 local yes no no yes" \
	"$rc $(st 4 state) $(yn grep -q 'is inside 192.168.40.0/24' "$T/err") $(yn has "$N" 'masquerade') $(sed -n '/set nat {/,/}/p' "$N" | grep -q elements && echo yes || echo no) $(yn grep -q 'conntrack -D -s 192.168.40.0/24$' "$T/log")"
check "... the address and DHCP stay (a local island)" "yes yes" "$(yn grep -qx 'brwifi100004 192.168.40.1/24' "$T/addrs") $(yn grep -q 'dhcp-range=set:n4' "$D")"
sed -i 's|^rnr0 .*|rnr0 10.9.0.50/24|' "$T/addrs"
run reroute; check "control: the next lease outside: routed again, NAT back" "routed yes" "$(st 4 state) $(yn has "$N" 'ip saddr { 192.168.40.0/24 } masquerade')"
printf 'WAN_PROTO=static\nWAN_PORT=rnr0\nWAN_VLAN=\nWAN_ADDR=192.168.40.9/24\n' > "$T/wancheck"
run reroute; check "a static WAN_ADDR inside the subnet: local" local "$(st 4 state)"
: > "$T/wancheck"; run reroute
# 7. refusals: each one alone, the network refused (inactive), the others run
refused() {	# <label> <line> [setup]
	NETS "network=4 name=Lab vlan=40 subnet=192.168.40.1/24 mode=gateway" "$2"
	run apply
	check "refused: $1" "inactive 1 routed" "$(st 9 state) $([ "$(st 9 refusals)" -ge 1 ] && echo 1) $(st 4 state)"
}
printf 'brwifi100004 - 40 lan\nbrwifi9 - 49 wifi\n' > "$T/l2list"
refused "a public subnet (D-GW9)" "network=9 vlan=49 subnet=8.8.8.1/24 mode=gateway"
refused "a /8 (D-GW9: /16../30)" "network=9 vlan=49 subnet=10.0.0.1/8 mode=gateway"
refused "a /31" "network=9 vlan=49 subnet=192.168.49.1/31 mode=gateway"
refused "the network address" "network=9 vlan=49 subnet=192.168.49.0/24 mode=gateway"
refused "the broadcast address" "network=9 vlan=49 subnet=192.168.49.255/24 mode=gateway"
refused "a subnet overlapping network 4's (file order)" "network=9 vlan=49 subnet=192.168.40.129/25 mode=gateway"
refused "a subnet overlapping the USB lifeline's address" "network=9 vlan=49 subnet=172.31.0.1/24 mode=gateway"
printf 'LAN_ADDR="192.168.49.1/24"\n' > "$T/lan.conf"
refused "a subnet overlapping LAN_ADDR (br-lan)" "network=9 vlan=49 subnet=192.168.49.1/24 mode=gateway"
: > "$T/lan.conf"
echo "brwifi50 192.168.49.1/24" > "$T/run/sta.routed"
refused "a subnet overlapping a Wi-Fi station routed network" "network=9 vlan=49 subnet=192.168.49.1/24 mode=gateway"
rm -f "$T/run/sta.routed"
printf 'WAN_VLAN=49\nWAN_PORT=rnr0\n' > "$T/wancheck"
refused "VLAN 49 = WAN_VLAN" "network=9 vlan=49 subnet=192.168.49.1/24 mode=gateway"
: > "$T/wancheck"
refused "VLAN 1 (Default)" "network=9 vlan=1 subnet=192.168.49.1/24 mode=gateway"
refused "isolate=2 (not 0|1)" "network=9 vlan=49 subnet=192.168.49.1/24 mode=gateway isolate=2"
NETS "network=4 name=Lab vlan=40 subnet=192.168.40.1/24 mode=gateway" "network=9 vlan=49 subnet=192.168.49.1/24 mode=gateway"
run apply; check "control: network 9 with a valid subnet runs" "routed routed" "$(st 9 state) $(st 4 state)"
echo "brwifi9 10.99.0.1/24" >> "$T/addrs"
NETS "network=4 name=Lab vlan=40 subnet=192.168.40.1/24 mode=gateway" "network=9 vlan=49 subnet=192.168.49.1/24 mode=gateway"
run apply; check "refused: the bridge carries an address of another owner (stopped: its address removed)" "inactive no" "$(st 9 state) $(yn grep -qx 'brwifi9 192.168.49.1/24' "$T/addrs")"
grep -v '^brwifi9 10.99' "$T/addrs" > "$T/a"; mv "$T/a" "$T/addrs"
printf 'brwifi100004 - 40 lan\nbrwifi9 rnr0 49 wifi\n' > "$T/l2list"
run apply; check "refused: the bridge still carries rnr0.49 (two gateways)" "inactive yes" "$(st 9 state) $(yn grep -q 'still carries the trunk VLAN rnr0.49' "$G/net/9")"
printf 'brwifi100004 - 40 lan\n' > "$T/l2list"
run apply; check "no bridge for VLAN 49 yet: inactive, logged why" "inactive yes" "$(st 9 state) $(yn grep -q 'no bridge for VLAN 49' "$G/net/9")"
# the cap: 16 gateway networks
l=; i=10; printf '# cap\n' > "$GT_BE98_NETWORKS"; : > "$T/l2list"
while [ $i -le 26 ]; do echo "network=$i vlan=$((100 + i)) subnet=10.$i.0.1/24 mode=gateway" >> "$GT_BE98_NETWORKS"; echo "brwifi$i - $((100 + i)) wifi" >> "$T/l2list"; i=$((i + 1)); done
run apply; check "the cap: 16 networks run, the 17th refused" "routed inactive yes" "$(st 25 state) $(st 26 state) $(yn grep -q 'more than 16' "$G/net/26")"
nftcheck "$N"; r=$?; [ $r = 2 ] || check "nft -c (kernel parser): 16 networks" 0 $r
# router mode applied: every gateway network refused (D-GW5)
NETS "network=4 name=Lab vlan=40 subnet=192.168.40.1/24 mode=gateway"; printf 'brwifi100004 - 40 lan\n' > "$T/l2list"
: > "$T/run/gt-be98-router.applied"
run apply; check "router mode applied: refused, nothing runs, forwarding released" "inactive 0" "$(st 4 state) $(cat "$T/ip_forward")"
rm -f "$T/run/gt-be98-router.applied"
run apply; check "control: router mode stopped: routed again" routed "$(st 4 state)"
# 8. DHCP fields (phase 3, re-checked here): a bad one turns DHCP off, the network runs
dh() {	# <label> <extra keys> <expect dhcp-range line or "">
	NETS "network=4 name=Lab vlan=40 subnet=$4 mode=gateway $2"; run apply
	check "DHCP: $1" "routed $3" "$(st 4 state) $(grep '^dhcp-range' "$D")"
}
dh "dhcp_start/end inside" "dhcp_start=192.168.40.10 dhcp_end=192.168.40.20 lease=1d" "dhcp-range=set:n4,192.168.40.10,192.168.40.20,255.255.255.0,1d" 192.168.40.1/24
dh "range outside the subnet: DHCP off" "dhcp_start=192.168.41.10 dhcp_end=192.168.41.20" "" 192.168.40.1/24
dh "range holding the gateway: DHCP off" "dhcp_start=192.168.40.1 dhcp_end=192.168.40.20" "" 192.168.40.1/24
dh "start after end: DHCP off" "dhcp_start=192.168.40.30 dhcp_end=192.168.40.20" "" 192.168.40.1/24
dh "only dhcp_start: DHCP off" "dhcp_start=192.168.40.30" "" 192.168.40.1/24
dh "a bad lease: DHCP off" "lease=12x" "" 192.168.40.1/24
dh "dhcp=0: no range" "dhcp=0" "" 192.168.40.1/24
dh "a /29 with the gateway .1: .2-.6" "" "dhcp-range=set:n4,192.168.40.2,192.168.40.6,255.255.255.248,12h" 192.168.40.1/29
dh "a /30 with the gateway .2: .1-.1" "" "dhcp-range=set:n4,192.168.40.1,192.168.40.1,255.255.255.252,12h" 192.168.40.2/30
# 9. the bridge moves (a lan-only bridge yields to the SSID's): the address follows
NETS "network=4 name=Lab vlan=40 subnet=192.168.40.1/24 mode=gateway"; run apply
printf 'brwifi8 - 40 wifi lan\n' > "$T/l2list"
run apply; check "the bridge moved: address off brwifi100004, on brwifi8, hold moved" "brwifi8 no yes no yes" \
	"$(st 4 bridge) $(yn grep -qx 'brwifi100004 192.168.40.1/24' "$T/addrs") $(yn grep -qx 'brwifi8 192.168.40.1/24' "$T/addrs") $(ex "$G/hold/brwifi100004") $(ex "$G/hold/brwifi8")"
# 10. the network becomes VLAN only: stopped BEFORE gt-be98-l2 sync carries its VLAN again
NETS "network=4 name=Lab vlan=40 subnet=192.168.40.1/24 mode=vlan"
run apply; check "mode=vlan again: address, rules, hold removed, flows deleted, then sync" \
	"ip rule del iif brwifi8 priority 184|ip rule del iif brwifi8 priority 185|ip addr del 192.168.40.1/24 dev brwifi8|conntrack -D -s 192.168.40.0/24|conntrack -D -d 192.168.40.0/24|l2 sync" \
	"$(log '^(ip rule del|ip addr del|conntrack|l2 sync)')"
check "... no gateway network left: tables deleted, dnsmasq stopped, forwarding back to 0, no hold" "yes yes 0 no no" \
	"$(yn grep -q 'delete table inet gt_be98_gw' "$T/last.nft") $(yn grep -q 'start-stop-daemon --stop' "$T/log") $(cat "$T/ip_forward") $(ex "$G/hold/brwifi8") $(ex "$G/net/4")"
check "... and the tables are not re-created (only the deletes)" no "$(yn grep -q '^table inet gt_be98_gw {$' "$T/last.nft")"
run apply; check "control: the next apply with none: nothing touched" "" "$(log '^(nft|ip (addr|rule|route)|dnsmasq|start-stop)')"
# 11. the rule set rejected: no network runs (no address without the rule set)
NETS "network=4 name=Lab vlan=40 subnet=192.168.40.1/24 mode=gateway"; printf 'brwifi100004 - 40 lan\n' > "$T/l2list"
cp "$GWT" "$T/gwrefuse"; sed -i 's/echo "# generated by gt-be98-gw - do not edit"$/echo "# generated by gt-be98-gw - do not edit REFUSE"/' "$T/gwrefuse"
: > "$T/log"; ${SH:-sh} "$T/gwrefuse" apply > /dev/null 2>&1; rc=$?
check "nft refusing the rule set: rc 1, inactive, no address set" "1 inactive " "$rc $(st 4 state) $(log '^ip addr replace')"
run apply; check "control: the same file accepted: routed" "0 routed" "$rc $(st 4 state)"
# 12. an address the kernel refuses: inactive, the rule set rebuilt without it
touch "$T/refuse-addr"; ${SH:-sh} "$GWT" stop >/dev/null 2>&1
run apply; check "address refused: rc 1, inactive, the rule set re-applied (no element)" "1 inactive no" "$rc $(st 4 state) $(sed -n '/set gw {/,/}/p' "$N" 2>/dev/null | grep -q brwifi && echo yes || echo no)"
rm -f "$T/refuse-addr"
# 13. stop: everything undone, the image's forwarding
run apply; run stop
check "stop: address, rules, tables, dnsmasq, hold, forwarding" "no yes yes yes no 0" \
	"$(yn grep -qx 'brwifi100004 192.168.40.1/24' "$T/addrs") $(yn grep -q 'ip rule del iif brwifi100004 priority 185' "$T/log") $(yn grep -q 'nft delete table inet gt_be98_gw' "$T/log") $(yn grep -q 'nft delete table ip gt_be98_gw_nat' "$T/log") $(ex "$G/hold/brwifi100004") $(cat "$T/ip_forward")"
# 14. forwarding held by another owner too: gw's release keeps it on
F hold sta; run apply; run stop
check "stop while sta holds forwarding: stays 1" "1 yes" "$(cat "$T/ip_forward") $(yn F held sta)"
F release sta
# 15. the WAN without a default route: unreachable (never leaked to another default)
rm -f "$T/route-rnr0"; run apply
check "no WAN default route: table 184 unreachable default" "ip route replace unreachable default table 184" "$(log '^ip route replace')"
echo "default dev pppoe-wan scope link" > "$T/route-pppoe-wan"; echo pppoe-wan > "$T/wanif"
run apply; check "PPPoE: default dev pppoe-wan, NAT and dnsmasq exclusion follow the WAN netdev" "ip route replace default dev pppoe-wan table 184 yes yes" \
	"$(log '^ip route replace') $(yn has "$N" 'oifname "pppoe-wan" ip saddr') $(yn grep -qx except-interface=pppoe-wan "$D")"
# the PPPoE session drops (pppd's ip-down: its default route is gone) and comes back (ip-up):
# the reroute each hook runs leaves table 184 unreachable, then on pppoe-wan again; the NAT
# keeps naming pppoe-wan throughout (a name: valid while the netdev is absent)
rm -f "$T/route-pppoe-wan"; run reroute
check "PPPoE down: table 184 unreachable (never leaked to the management default), NAT still on pppoe-wan" "ip route replace unreachable default table 184 yes" \
	"$(log '^ip route replace') $(yn has "$N" 'oifname "pppoe-wan" ip saddr')"
echo "default dev pppoe-wan scope link" > "$T/route-pppoe-wan"; run reroute
check "  PPPoE up again: default dev pppoe-wan in table 184" "ip route replace default dev pppoe-wan table 184" "$(log '^ip route replace')"
run stop
# 16. the wiring (text checks of the image's files)
S=$here/..
fol() { awk -v f="$2" '/^'"$2"'\(\) \{/ { x = 1 } x && /GW_FOLLOW/ { n++ } x && /^}/ { x = 0 } END { print n + 0 }' "$1"; }
check "gt-be98-wifi: start and reload run GW_FOLLOW (rc-service --ifstarted gt-be98-gw reload)" "1 1 yes" \
	"$(fol "$S/src/init.d/gt-be98-wifi" start) $(fol "$S/src/init.d/gt-be98-wifi" reload) $(yn grep -q 'GW_FOLLOW=${GT_BE98_GW_FOLLOW-rc-service --ifstarted gt-be98-gw reload}' "$S/src/init.d/gt-be98-wifi")"
check "gt-be98-os.mk: the tools, the service, the dhcpcd hook installed; gt-be98-gw in the default runlevel" "yes yes yes yes" \
	"$(yn grep -q 'gt-be98-l2 gt-be98-fwd gt-be98-gw; do' "$S/gt-be98-os.mk") $(yn grep -q 'gt-be98-hostkeys gt-be98-wan gt-be98-gw' "$S/gt-be98-os.mk") $(yn grep -q 'dhcpcd-hooks/09-gt-be98-gw$' "$S/gt-be98-os.mk") $(yn grep -q 'gt-be98-lan gt-be98-gw; do' "$S/gt-be98-os.mk")"
check "the service answers features (an extra command, so when stopped too)" "features|features gateway" \
	"$(GT_BE98_GW="$GWT"; extra_commands=; . "$S/src/init.d/gt-be98-gw"; echo "$extra_commands|$(features)")"
check "no routed owner writes ip_forward itself any more (gt-be98-fwd only)" "" \
	"$(grep -ln 'ip_forward=\|net.ipv4.ip_forward' "$S/src/init.d/"* "$S/src/sbin/"* | grep -v 'gt-be98-fwd$' | tr '\n' ' ')"
echo "gt-be98-gw-test: $pass ok, $fail failed"
[ $fail -eq 0 ]

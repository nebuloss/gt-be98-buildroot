#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# Offline test of sbin/gt-be98-gw (gateway networks) and sbin/gt-be98-fwd
# (the one owner of ip_forward): sh test/gt-be98-gw-test.sh
# No device, no root. Fakes: `ip` keeps the box's addresses and logs every
# call; gt-be98-l2 (list from a file, sync logged), gt-be98-wan (ifname,
# check from files), nft (logs, copies the file; a file with REFUSE is
# rejected), conntrack, dnsmasq (a sleeper writing its pid file, counting
# the SIGHUPs it gets in $FAKE/hups), start-stop-daemon. The real gt-be98-fwd writes a fake ip_forward file.
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
	GT_BE98_GW_RESOLV="$T/resolv.conf" GT_BE98_SYSNET="$T/sys" GT_BE98_DHCP_HOSTS="$T/dhcp-hosts.conf"
mkdir -p "$T/bin" "$T/run" "$T/sys"
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
"link set dev "*" address "*)	[ -f "$FAKE/refuse-mac" ] && exit 2; mkdir -p "$FAKE/sys/$4"; echo "$6" > "$FAKE/sys/$4/address" ;;
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
sh -c 'trap "echo hup >> \"\$FAKE/hups\"" HUP; trap "kill \$p 2>/dev/null; exit 0" TERM; while :; do sleep 1000 & p=$!; wait $p; kill $p 2>/dev/null; done' &
echo $! > "$(sed -n 's/^pid-file=//p' "$c")"
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
run stop
# 15b. the shared router MAC (G6b): every gateway bridge takes rnr1's MAC, before its address
rm -f "$T/route-pppoe-wan"; echo rnr0 > "$T/wanif"; echo "default via 10.9.0.1 dev rnr0 proto dhcp" > "$T/route-rnr0"
mac() { cat "$T/sys/$1/address" 2>/dev/null; }
NETS "network=4 name=Lab vlan=40 subnet=192.168.40.1/24 mode=gateway" "network=6 name=Guest vlan=60 subnet=192.168.60.1/24 mode=gateway"
printf 'brwifi8 - 40 wifi lan\nbrwifi9 - 60 wifi\n' > "$T/l2list"
mkdir -p "$T/sys/rnr1" "$T/sys/brwifi8" "$T/sys/brwifi9"
echo 02:00:00:00:00:a8 > "$T/sys/brwifi8/address"; echo 02:00:00:00:00:a9 > "$T/sys/brwifi9/address"
run apply; check "control: no rnr1 in sysfs: no MAC set, both routed" "routed routed 02:00:00:00:00:a8 02:00:00:00:00:a9 " \
	"$(st 4 state) $(st 6 state) $(mac brwifi8) $(mac brwifi9) $(log '^ip link set')"
run stop; echo 02:00:00:00:00:01 > "$T/sys/rnr1/address"
run apply; check "two gateway bridges: both take rnr1's MAC (one parser router-MAC filter for all)" "routed routed 02:00:00:00:00:01 02:00:00:00:00:01" \
	"$(st 4 state) $(st 6 state) $(mac brwifi8) $(mac brwifi9)"
check "... the MAC set before the address, per bridge" \
	"ip link set dev brwifi8 address 02:00:00:00:00:01|ip addr replace 192.168.40.1/24 dev brwifi8|ip link set dev brwifi9 address 02:00:00:00:00:01|ip addr replace 192.168.60.1/24 dev brwifi9" \
	"$(log '^ip (link set|addr replace)')"
run stop; run apply; check "control: the MAC already in place: no ip link set" "routed " "$(st 4 state) $(log '^ip link set')"
run stop; echo 02:00:00:00:00:a8 > "$T/sys/brwifi8/address"; touch "$T/refuse-mac"
run apply; check "a MAC the kernel refuses: logged, the bridge keeps its own, still routed" "routed 02:00:00:00:00:a8 yes" \
	"$(st 4 state) $(mac brwifi8) $(yn grep -q 'brwifi8: router MAC 02:00:00:00:00:01 refused' "$T/err")"
rm -f "$T/refuse-mac"; run stop
echo zz > "$T/sys/rnr1/address"; echo 02:00:00:00:00:a8 > "$T/sys/brwifi8/address"
run apply; check "control: a malformed rnr1 address: ignored" "routed " "$(st 4 state) $(log '^ip link set')"
run stop; rm -rf "$T/sys/rnr1" "$T/sys/brwifi8" "$T/sys/brwifi9"
# ===== phase 3: DHCP and DNS options, static leases, the lease table =====
NETS "network=3 name=Up vlan=30 subnet=192.168.30.1/24" \
	"network=4 name=Lab vlan=40 subnet=192.168.40.1/24 mode=gateway dns=1.1.1.1,9.9.9.9 domain=lab.example lease=30m"
printf 'brwifi100004 - 40 lan\n' > "$T/l2list"; echo "default via 10.9.0.1 dev rnr0 proto dhcp" > "$T/route-rnr0"; rm -f "$GT_BE98_DHCP_HOSTS"
run apply
check "P3: custom DNS servers handed out, the domain, the lease time" \
	"dhcp-option=tag:n4,option:dns-server,1.1.1.1,9.9.9.9|dhcp-range=set:n4,192.168.40.100,192.168.40.199,255.255.255.0,30m|domain=lab.example,192.168.40.0/24" \
	"$(grep -E '^(dhcp-range|dhcp-option=tag:n4,option:dns|domain=)' "$D" | sort | tr '\n' '|' | sed 's/|$//')"
check "P3: the router option stays the box" yes "$(yn grep -qx 'dhcp-option=tag:n4,option:router,192.168.40.1' "$D")"
dn() {	# <label> <extra keys> <expect: range|norange> <expect domain line or "">
	NETS "network=4 name=Lab vlan=40 subnet=192.168.40.1/24 mode=gateway $2"; run apply
	check "P3: $1" "routed $3 $4" "$(st 4 state) $(grep -q '^dhcp-range' "$D" && echo range || echo norange) $(grep '^domain=' "$D")"
}
dn "control: dns= one server" "dns=10.9.0.1" range ""
dn "dns=127.0.0.1: DHCP off" "dns=127.0.0.1" norange ""
dn "dns=0.1.2.3: DHCP off" "dns=0.1.2.3" norange ""
dn "dns=224.0.0.1 (multicast): DHCP off" "dns=224.0.0.1" norange ""
dn "dns twice: DHCP off" "dns=1.1.1.1,1.1.1.1" norange ""
dn "dns trailing comma: DHCP off" "dns=1.1.1.1," norange ""
dn "control: 4 dns servers" "dns=1.1.1.1,1.0.0.1,9.9.9.9,8.8.8.8" range ""
dn "5 dns servers: DHCP off" "dns=1.1.1.1,1.0.0.1,9.9.9.9,8.8.8.8,8.8.4.4" norange ""
dn "dns=1.1.1 (not IPv4): DHCP off" "dns=1.1.1" norange ""
dn "control: a domain" "domain=home.arpa" range "domain=home.arpa,192.168.40.0/24"
dn "domain upper case (never re-interpreted): DHCP off, no domain" "domain=Lab.example" norange ""
dn "domain with an empty label: DHCP off, no domain" "domain=lab..example" norange ""
dn "domain with a leading '-': DHCP off, no domain" "domain=-lab.example" norange ""
dn "domain with a label ending in '-': DHCP off, no domain" "domain=lab-.example" norange ""
L64=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
dn "domain with a 64-character label: DHCP off, no domain" "domain=$L64.example" norange ""
dn "control: a 63-character label" "domain=${L64#a}.example" range "domain=${L64#a}.example,192.168.40.0/24"
dn "dhcp=0 keeps the domain (DNS), no range" "dhcp=0 domain=lab.example" norange "domain=lab.example,192.168.40.0/24"
dn "lease=1m (under dnsmasq's 2-minute floor): DHCP off" "lease=1m" norange ""
dn "control: lease=2m" "lease=2m" range ""
dn "control: lease=365d" "lease=365d" range ""
dn "lease=366d: DHCP off" "lease=366d" norange ""
dn "lease=8761h: DHCP off" "lease=8761h" norange ""
dn "lease=0h: DHCP off" "lease=0h" norange ""
dn "control: lease=infinite" "lease=infinite" range ""
check "P3: the reason is in the state" yes "$(NETS 'network=4 name=Lab vlan=40 subnet=192.168.40.1/24 mode=gateway lease=1m'; run apply; yn grep -q "lease '1m': 2 minutes to 365 days" "$T/err")"
# static leases: rendered for the running DHCP networks, each refusal a comment
NETS "network=3 name=Up vlan=30 subnet=192.168.30.1/24" "network=4 name=Lab vlan=40 subnet=192.168.40.1/24 mode=gateway" \
	"network=6 name=Off vlan=41 subnet=10.41.0.1/16 mode=gateway dhcp=0"
printf 'brwifi100004 - 40 lan\nbrwifi7 - 41 wifi\n' > "$T/l2list"
cat > "$GT_BE98_DHCP_HOSTS" <<'H'
# written by the web UI
network=4 mac=02:00:00:00:00:10 ip=192.168.40.10 name=printer
network=4 mac=02:00:00:00:00:11 ip=192.168.40.150
network=4 mac=02:00:00:00:00:12 ip=192.168.41.12
network=4 mac=02:00:00:00:00:13 ip=192.168.40.1
network=4 mac=02:00:00:00:00:14 ip=192.168.40.255
network=4 mac=03:00:00:00:00:15 ip=192.168.40.15
network=4 mac=02:00:00:00:00:1A ip=192.168.40.16
network=4 mac=02:00:00:00:00:17 ip=192.168.40.10
network=4 mac=02:00:00:00:00:10 ip=192.168.40.18
network=4 mac=02:00:00:00:00:19 ip=192.168.40.19 name=PRINTER
network=4 mac=02:00:00:00:00:20 ip=192.168.40.20 name=bad_name
network=4 mac=00:00:00:00:00:00 ip=192.168.40.21
network=3 mac=02:00:00:00:00:30 ip=192.168.30.30
network=6 mac=02:00:00:00:00:60 ip=10.41.0.60
network=4 ip=192.168.40.22
H
pid=; run apply; H=$G/dhcp-hosts
check "P3: static leases served: the two valid ones of network 4, in file order" "02:00:00:00:00:10,192.168.40.10,printer|02:00:00:00:00:11,192.168.40.150" \
	"$(grep -v '^#' "$H" | tr '\n' '|' | sed 's/|$//')"
check "P3: every invalid entry refused with its reason (11), none for the unserved networks 3 and 6" \
	"11 yes yes yes yes yes yes yes yes yes yes no no" "$(grep -c '^# refused' "$H") $(yn grep -q '192.168.41.12: ip 192.168.41.12: outside' "$H") $(yn grep -q '192.168.40.1: ip 192.168.40.1: the gateway address' "$H") $(yn grep -q '192.168.40.255: ip 192.168.40.255: the network or broadcast' "$H") $(yn grep -q "mac '03:00:00:00:00:15'" "$H") $(yn grep -q "mac '02:00:00:00:00:1A'" "$H") $(yn grep -q '192.168.40.10: ip 192.168.40.10: reserved for another device' "$H") $(yn grep -q 'mac 02:00:00:00:00:10: has a static lease on network 4' "$H") $(yn grep -q 'name PRINTER: used on network 4' "$H") $(yn grep -q "name 'bad_name'" "$H") $(yn grep -q 'mac 00:00:00:00:00:00: not a device' "$H") $(yn grep -q '30:30\|0:60' "$H") $(yn grep -q '10.41.0.60' "$H")"
check "P3: an entry without a mac is refused, logged" "yes yes" "$(yn grep -q "mac '?'" "$H") $(yn grep -q 'static lease refused: network 4' "$T/err")"
check "P3: the hosts file is world-readable (dnsmasq re-reads it as nobody)" 644 "$(stat -c %a "$H")"
check "P3: hosts-text = the file" yes "$([ "$(sh "$GWT" hosts-text)" = "$(cat "$H")" ] && echo yes || echo no)"
# a change of the static leases ALONE: SIGHUP, the same pid (GW3's contract)
waithup() { i=0; while [ $i -lt 30 ] && [ "$(wc -l < "$T/hups" 2>/dev/null || echo 0)" -lt "$1" ]; do sleep 0.1; i=$((i + 1)); done; wc -l < "$T/hups" 2>/dev/null | tr -d ' ' || echo 0; }
: > "$T/hups"; pid=$(cat "$G/dnsmasq.pid"); r0=$(sed -n 's/^restarts //p' "$G/dnsmasq.stats")
printf '1700000000 02:00:00:00:00:99 192.168.40.123 laptop 01:02:00:00:00:00:99\n' > "$G/leases"
echo "network=4 mac=02:00:00:00:00:40 ip=192.168.40.40 name=nas" >> "$GT_BE98_DHCP_HOSTS"
run apply
check "P3 (GW3): a static lease added: SIGHUP, dnsmasq's pid unchanged, not restarted, counted" "1 $pid $r0 1" \
	"$(waithup 1) $(cat "$G/dnsmasq.pid") $(sed -n 's/^restarts //p' "$G/dnsmasq.stats") $(sed -n 's/^hups //p' "$G/dnsmasq.stats")"
check "P3: ... the new entry served, the lease table untouched" "yes yes" \
	"$(yn grep -qx '02:00:00:00:00:40,192.168.40.40,nas' "$H") $(yn grep -qx '1700000000 02:00:00:00:00:99 192.168.40.123 laptop 01:02:00:00:00:00:99' "$G/leases")"
run apply; check "P3: control: nothing changed: no SIGHUP, no restart" "1 $pid" "$(sleep 0.3; waithup 1) $(cat "$G/dnsmasq.pid")"
check "P3: status: dnsmasq pid, restarts, hups, static" "dnsmasq pid=$pid restarts=$r0 hups=1 static=3" "$(sh "$GWT" status | grep '^dnsmasq ')"
# the range and the lease time change (GW3b's contract): a restart that keeps the lease table
NETS "network=3 name=Up vlan=30 subnet=192.168.30.1/24" "network=4 name=Lab vlan=40 subnet=192.168.40.1/24 mode=gateway dhcp_start=192.168.40.50 dhcp_end=192.168.40.150 lease=2m" \
	"network=6 name=Off vlan=41 subnet=10.41.0.1/16 mode=gateway dhcp=0"
run apply
check "P3 (GW3b): range + lease changed: restarted (new pid), no SIGHUP, the lease table kept byte for byte" "yes 1 $((r0 + 1)) yes" \
	"$([ "$(cat "$G/dnsmasq.pid")" != "$pid" ] && echo yes || echo no) $(waithup 1) $(sed -n 's/^restarts //p' "$G/dnsmasq.stats") $(yn grep -qx '1700000000 02:00:00:00:00:99 192.168.40.123 laptop 01:02:00:00:00:00:99' "$G/leases")"
check "P3: ... the new range and lease time rendered" yes "$(yn grep -qx 'dhcp-range=set:n4,192.168.40.50,192.168.40.150,255.255.255.0,2m' "$D")"
# the lease table: each lease with its network and whether it is static
printf '1700000000 02:00:00:00:00:99 192.168.40.123 laptop *\n0 02:00:00:00:00:40 192.168.40.40 nas *\n1700000100 02:00:00:00:00:77 172.20.0.7 * *\nbogus line\n' > "$G/leases"
check "P3: leases: network, mac, ip, expiry, name, static" \
	"lease 4 02:00:00:00:00:99 192.168.40.123 1700000000 laptop static=0|lease 4 02:00:00:00:00:40 192.168.40.40 0 nas static=1|lease - 02:00:00:00:00:77 172.20.0.7 1700000100 * static=0" \
	"$(sh "$GWT" leases | tr '\n' '|' | sed 's/|$//')"
rm -f "$G/leases"; check "P3: leases: no table, no line, rc 0" "0 " "$(sh "$GWT" leases > "$T/o"; echo "$? $(cat "$T/o")")"
# the cap: STATIC_MAX (256) per network
NETS "network=6 name=Big vlan=41 subnet=10.41.0.1/16 mode=gateway"; printf 'brwifi7 - 41 wifi\n' > "$T/l2list"
i=0; : > "$GT_BE98_DHCP_HOSTS"
while [ $i -lt 257 ]; do printf 'network=6 mac=02:00:00:00:%02x:%02x ip=10.41.%d.%d\n' $((i / 256)) $((i % 256)) $((1 + i / 200)) $((1 + i % 200)) >> "$GT_BE98_DHCP_HOSTS"; i=$((i + 1)); done
run apply
check "P3: the cap: 256 static leases served, the 257th refused" "256 1" "$(grep -vc '^#' "$H") $(grep -c 'more than 256 static leases' "$H")"
# stop: the hosts file goes, the lease table stays (D-GW7)
printf '1700000000 02:00:00:00:00:99 10.41.0.99 * *\n' > "$G/leases"
run stop; check "P3: stop: the hosts file removed, the lease table kept" "no yes" "$(ex "$H") $(ex "$G/leases")"
rm -f "$GT_BE98_DHCP_HOSTS" "$G/leases"
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

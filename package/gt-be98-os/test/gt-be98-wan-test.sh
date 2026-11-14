#!/bin/sh
# shellcheck shell=busybox
# SPDX-License-Identifier: GPL-2.0
# Offline test of sbin/gt-be98-wan and its integration points (no device, no
# root):  sh test/gt-be98-wan-test.sh   (SH=dash|bash to pick the shell)
# Every tool it drives is a fake that logs its command line to $FAKE/log;
# the checks are on those commands and on the files the tool writes. Each
# refusal has its control (the same config with the one bad value fixed).
# Not with "busybox sh" (its ip/sysctl/start-stop-daemon applets run before
# PATH, so the fakes would not be reached; the image has no busybox).
set -u
case "${SH:-sh}" in *busybox*) echo "skip: SH=$SH (busybox applets shadow the fakes, see the header)"; exit 0 ;; esac
SH=${SH:-sh}
here=$(cd "$(dirname "$0")" && pwd)
SRC="$here/../src"
W="$SRC/sbin/gt-be98-wan"
T=$(mktemp -d)
trap 'for f in $(find "$T" -name "*.pid"); do kill "$(head -n1 "$f")" 2>/dev/null; done; [ -n "${wp:-}" ] && kill "$wp" 2>/dev/null; rm -rf "$T"' EXIT
FAKE=$T/fake; export FAKE
mkdir -p "$FAKE" "$T/bin" "$T/net/rnr0" "$T/etc" "$T/run" "$T/resolv"
echo up > "$T/net/rnr0/operstate"; echo 1500 > "$T/net/rnr0/mtu"
fail=0 n=0
check() {
	n=$((n + 1))
	if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want [$2] got [$3]"; fail=$((fail + 1)); fi
}
has() { grep -qF -- "$2" "$1" 2>/dev/null; }
yes_no() { if "$@"; then echo yes; else echo no; fi; }

for t in nft sysctl logger rc-service modprobe start-stop-daemon; do
	printf '#!/bin/sh\necho "%s $*" >> "$FAKE/log"\nexit 0\n' "$t" > "$T/bin/$t"
done
# ip: logs; "link add ... name X" creates $SYSNET/X; "link del X" removes it;
# "-6 route show default dev X" answers $FAKE/route6-X
cat > "$T/bin/ip" <<'X'
#!/bin/sh
echo "ip $*" >> "$FAKE/log"
case "$*" in
"link add link "*) mkdir -p "$GT_BE98_SYSNET/$6"; echo 1500 > "$GT_BE98_SYSNET/$6/mtu" ;;
"link del "*) rm -rf "$GT_BE98_SYSNET/$3" ;;
"-6 route show default dev "*) cat "$FAKE/route6-$6" 2>/dev/null ;;
"-4 route show default dev "*) cat "$FAKE/route4-$6" 2>/dev/null ;;
"-4 -o addr show dev "*) cat "$FAKE/addr4-$6" 2>/dev/null ;;
esac
exit 0
X
# dhcpcd: logs (the "running" check reads $DHCPCD_PID)
printf '#!/bin/sh\necho "dhcpcd $*" >> "$FAKE/log"\n' > "$T/bin/dhcpcd"
# pppd: keeps a copy of its option file and its mode, writes the pid file
cat > "$T/bin/pppd" <<'X'
#!/bin/sh
echo "pppd $*" >> "$FAKE/log"
cp "$2" "$FAKE/pppd.conf.seen"; stat -c %a "$2" > "$FAKE/pppd.conf.mode"
sleep 1000 & echo $! > "$PPP_RUNDIR/ppp-wan.pid"
exit 0
X
chmod +x "$T/bin/"*
PATH="$T/bin:$PATH"
export GT_BE98_WAN_CONF="$T/etc/wan.conf" GT_BE98_WAN_RUN="$T/run" GT_BE98_SYSNET="$T/net" \
	DHCPCD_BASE="$SRC/etc/dhcpcd.conf" DHCPCD_PID="$T/dhcpcd.pid" DHCPCD_RESOLV_DIR="$T/resolv" \
	RESOLV_CONF="$T/resolv.conf" GT_BE98_WIFI_L2="$T/l2.conf" GT_BE98_WIFI_AP="$T/none" \
	GT_BE98_LAN_CONF="$T/none" GT_BE98_WAN_SELF="$SH $W" PPP_RUNDIR="$T/run" IFACE_WAIT=1 \
	ROUTER_APPLIED="$T/none"
sleep 1000 & echo $! > "$T/dhcpcd.pid"
wan() { $SH "$W" "$@"; }
reset() { [ -f "$T/run/trial.pid" ] && kill "$(cat "$T/run/trial.pid")" 2>/dev/null; rm -rf "$T/run" "$T/etc/wan.conf" "$FAKE/log" "$FAKE"/pppd.* "$T/net/rnr0."*; mkdir -p "$T/run"; : > "$FAKE/log"; }
cfg() { printf '%s\n' "$@" > "$T/c.conf"; }
# rc of check on the config given as lines
ck() { cfg "$@"; wan check "$T/c.conf" >/dev/null 2>&1; echo $?; }

# ---- 1. the default: no file = DHCP on rnr0, nothing changes -----------------------
reset
check "default: proto" "WAN_PROTO=dhcp" "$(wan check | sed -n 1p)"
check "default: ifname" rnr0 "$(wan ifname)"
p=$(wan dhcpcd-conf)
check "default: dhcpcd config is a byte copy of the image's" yes "$(yes_no cmp -s "$p" "$SRC/etc/dhcpcd.conf")"
wan start
check "default: start touches nothing (no ip/nft/sysctl/pppd)" "" "$(grep -E '^(ip|nft|sysctl|pppd|start-stop-daemon) ' "$FAKE/log")"
check "default: status" "proto=dhcp ifname=rnr0 config=default" \
	"$(wan status | grep -E '^(proto|ifname|config)=' | tr '\n' ' ' | sed 's/ $//')"

# ---- 2. validation, each refusal with its control -------------------------------------
check "proto bogus refused" 1 "$(ck WAN_PROTO=dhcpv4)"
check "  control: dhcp" 0 "$(ck WAN_PROTO=dhcp)"
check "port eth0 refused" 1 "$(ck WAN_PORT=eth0)"
check "  control: rnr3" 0 "$(ck WAN_PORT=rnr3)"
for v in 0 4095 007 x; do check "vlan $v refused" 1 "$(ck WAN_VLAN=$v)"; done
check "  control: vlan 835" 0 "$(ck WAN_VLAN=835)"
printf 'WIFI_TRUNK=rnr0\nWIFI_VLANS="brwifi1:20 brwifi2:30"\n' > "$T/l2.conf"
check "vlan = a Wi-Fi trunk VLAN refused" 1 "$(ck WAN_VLAN=30)"
check "  control: same VID on another port" 0 "$(ck WAN_PORT=rnr3 WAN_VLAN=30)"
rm -f "$T/l2.conf"
S="WAN_PROTO=static"
check "static gw outside the subnet refused" 1 "$(ck $S WAN_ADDR=192.0.2.10/24 WAN_GW=198.51.100.1)"
check "  control: gw inside" 0 "$(ck $S WAN_ADDR=192.0.2.10/24 WAN_GW=192.0.2.1)"
check "static without gw refused" 1 "$(ck $S WAN_ADDR=192.0.2.10/24)"
check "static gw = own address refused" 1 "$(ck $S WAN_ADDR=192.0.2.10/24 WAN_GW=192.0.2.10)"
check "static addr without prefix refused" 1 "$(ck $S WAN_ADDR=192.0.2.10 WAN_GW=192.0.2.1)"
check "static octet 256 refused" 1 "$(ck $S WAN_ADDR=192.0.2.256/24 WAN_GW=192.0.2.1)"
check "static /32 with an off-subnet gw (ISP style) accepted" 0 "$(ck $S WAN_ADDR=192.0.2.10/32 WAN_GW=198.51.100.1)"
check "4 DNS refused" 1 "$(ck $S WAN_ADDR=192.0.2.10/24 WAN_GW=192.0.2.1 'WAN_DNS="1.1.1.1 8.8.8.8 9.9.9.9 1.0.0.1"')"
check "  control: 3 DNS" 0 "$(ck $S WAN_ADDR=192.0.2.10/24 WAN_GW=192.0.2.1 'WAN_DNS="1.1.1.1 8.8.8.8 9.9.9.9"')"
check "WAN_ADDR on dhcp refused" 1 "$(ck WAN_ADDR=192.0.2.10/24)"
P="WAN_PROTO=pppoe"
check "pppoe without user refused" 1 "$(ck $P)"
check "  control: with user" 0 "$(ck $P PPPOE_USER=u@isp)"
check "pppoe user with a quote refused" 1 "$(ck $P 'PPPOE_USER=a"b')"
check "pppoe password with a backslash refused" 1 "$(ck $P PPPOE_USER=u 'PPPOE_PASS=a\b')"
check "  control: password with spaces and # ;" 0 "$(ck $P PPPOE_USER=u 'PPPOE_PASS="a b#c;d"')"
check "pppoe mtu 1501 refused (pppd's ceiling: 1500)" 1 "$(ck $P PPPOE_USER=u PPPOE_MTU=1501)"
check "pppoe mtu 1279 refused" 1 "$(ck $P PPPOE_USER=u PPPOE_MTU=1279)"
check "  control: 1480" 0 "$(ck $P PPPOE_USER=u PPPOE_MTU=1480)"
check "  control: 1500 (RFC 4638)" 0 "$(ck $P PPPOE_USER=u PPPOE_MTU=1500)"
check "WAN_MTU 10241 refused (the driver's max 10240)" 1 "$(ck WAN_MTU=10241)"
check "WAN_MTU 1279 refused" 1 "$(ck WAN_MTU=1279)"
check "  control: WAN_MTU 9000 and 10240 (jumbo)" "0 0" "$(ck WAN_MTU=9000) $(ck WAN_MTU=10240)"
check "  control: static WAN_MTU 9000" 0 "$(ck WAN_PROTO=static WAN_ADDR=192.0.2.10/24 WAN_GW=192.0.2.1 WAN_MTU=9000)"
check "WAN_MTU on pppoe refused" 1 "$(ck $P PPPOE_USER=u WAN_MTU=1400)"
check "PPPOE_USER on dhcp refused" 1 "$(ck PPPOE_USER=u)"
check "PD LANs without IPv6 refused" 1 "$(ck WAN_PD_LANS=brwifi1)"
check "  control: with WAN_IPV6=1" 0 "$(ck WAN_IPV6=1 WAN_PD_LANS=brwifi1)"
check "PD LAN rnr1 refused" 1 "$(ck WAN_IPV6=1 WAN_PD_LANS=rnr1)"
check "PD LAN eth0 refused" 1 "$(ck WAN_IPV6=1 WAN_PD_LANS=eth0)"
check "  control: br-lan" 0 "$(ck WAN_IPV6=1 WAN_PD_LANS=br-lan)"
check "PD /64 for 2 LANs refused" 1 "$(ck WAN_IPV6=1 WAN_PD_LEN=64 'WAN_PD_LANS="brwifi1 br-lan"')"
check "  control: /63" 0 "$(ck WAN_IPV6=1 WAN_PD_LEN=63 'WAN_PD_LANS="brwifi1 br-lan"')"
check "metric 0 refused" 1 "$(ck WAN_METRIC=0)"
cfg $P PPPOE_USER=u PPPOE_PASS=s3cr3tpw
check "check never prints the password" no "$(yes_no grep -q s3cr3tpw <<EOF
$(wan check "$T/c.conf" 2>&1)
EOF
)"
cfg $P 'PPPOE_USER=a"b' PPPOE_PASS=s3cr3tpw
check "a refusal never prints the password" no "$(yes_no grep -q s3cr3tpw <<EOF
$(wan check "$T/c.conf" 2>&1)
EOF
)"

# ---- 3. dhcpcd config ------------------------------------------------------------------
reset
printf 'WAN_PROTO=static\nWAN_VLAN=835\nWAN_ADDR=192.0.2.10/24\nWAN_GW=192.0.2.1\nWAN_DNS="192.0.2.53"\n' > "$T/etc/wan.conf"
p=$(wan dhcpcd-conf)
check "static vlan: allowinterfaces + the VLAN" "allowinterfaces eth* usb* enx* rnr0 rnr0.835" "$(grep '^allowinterfaces' "$p")"
check "static vlan: deny unchanged" "$(grep '^denyinterfaces' "$SRC/etc/dhcpcd.conf")" "$(grep '^denyinterfaces' "$p")"
check "static vlan: block" "interface rnr0.835
static ip_address=192.0.2.10/24
static routers=192.0.2.1
static domain_name_servers=192.0.2.53" "$(sed -n '/^interface rnr0.835/,$p' "$p")"
check "static vlan: the image's lines kept" "$(grep -c . "$SRC/etc/dhcpcd.conf")" \
	"$(sed -n '1,/^# --- gt-be98-wan/p' "$p" | grep -v '^# --- gt-be98-wan' | grep -c .)"
printf 'WAN_IPV6=1\nWAN_PD_LEN=56\nWAN_PD_LANS="brwifi1 br-lan"\n' > "$T/etc/wan.conf"
p=$(wan dhcpcd-conf)
check "PD: allow adds the LANs" "allowinterfaces eth* usb* enx* rnr0 brwifi1 br-lan" "$(grep '^allowinterfaces' "$p")"
check "PD: deny loses br* only" "denyinterfaces lo bcawl* wl* veth* dummy* tun*" "$(grep '^denyinterfaces' "$p")"
check "PD: ia_pd line" "ia_pd 2/::/56 brwifi1/0/64 br-lan/1/64" "$(grep '^ia_pd' "$p")"
check "PD: rnr0 block" "interface rnr0
ipv6rs
ia_na 1" "$(sed -n '/^interface rnr0$/,/^ia_na/p' "$p")"
check "PD: LAN block" "interface brwifi1
noipv4
noipv6rs
nodhcp6" "$(sed -n '/^interface brwifi1/,+3p' "$p")"
printf 'WAN_PROTO=pppoe\nPPPOE_USER=u\nWAN_IPV6=1\n' > "$T/etc/wan.conf"
p=$(wan dhcpcd-conf)
check "pppoe+v6: dhcpcd on pppoe-wan, IPv6 only" "interface pppoe-wan
ipv6only
ipv6rs" "$(sed -n '/^interface pppoe-wan/,+2p' "$p")"
printf 'WAN_PROTO=pppoe\nPPPOE_USER=u\n' > "$T/etc/wan.conf"
p=$(wan dhcpcd-conf)
check "pppoe v4 only: no dhcpcd block (rnr0 untouched)" "" "$(grep '^interface' "$p")"
printf 'WAN_PROTO=bogus\n' > "$T/etc/wan.conf"
check "invalid config: dhcpcd keeps the image's file" "$SRC/etc/dhcpcd.conf" "$(wan dhcpcd-conf 2>/dev/null)"
check "  ... and rc 0" 0 "$(wan dhcpcd-conf >/dev/null 2>&1; echo $?)"

# ---- 4. start / stop: VLAN, PPPoE, nft, PD ----------------------------------------------
reset
printf 'WAN_PROTO=pppoe\nWAN_VLAN=835\nPPPOE_USER=fti/u@isp\nPPPOE_PASS="p w#1"\nPPPOE_SERVICE=svc\n' > "$T/etc/wan.conf"
wan start 2>/dev/null
check "pppoe vlan: VLAN created" yes "$(yes_no has "$FAKE/log" "ip link add link rnr0 name rnr0.835 type vlan id 835")"
check "pppoe: module loaded" yes "$(yes_no has "$FAKE/log" "modprobe -q pppoe")"
check "pppoe: pppd option file mode" 600 "$(cat "$FAKE/pppd.conf.mode" 2>/dev/null)"
for l in "plugin pppoe.so" "nic-rnr0.835" "ifname pppoe-wan" 'user "fti/u@isp"' 'password "p w#1"' \
	'pppoe-service "svc"' "defaultroute-metric 4000" "mtu 1492" "mru 1492" "ip-up-script $T/run/ppp-ip-up" noipv6; do
	check "pppd: $l" yes "$(yes_no grep -qxF "$l" "$FAKE/pppd.conf.seen")"
done
check "pppd: no pppoe-ac when unset" no "$(yes_no grep -q pppoe-ac "$FAKE/pppd.conf.seen")"
check "nft: MSS clamp out" yes "$(yes_no has "$T/run/wan.nft" 'oifname "pppoe-wan" tcp flags syn tcp option maxseg size set rt mtu')"
check "nft: MSS clamp in" yes "$(yes_no has "$T/run/wan.nft" 'iifname "pppoe-wan" tcp flags syn tcp option maxseg size set rt mtu')"
check "nft: input filter on pppoe-wan" yes "$(yes_no has "$T/run/wan.nft" 'iifname "pppoe-wan" drop')"
check "nft: never on rnr0" no "$(yes_no has "$T/run/wan.nft" '"rnr0"')"
check "nft: checked then loaded" "nft -c -f $T/run/wan.nft
nft -f $T/run/wan.nft" "$(grep '^nft' "$FAKE/log")"
pid=$(cat "$T/run/ppp-wan.pid")
: > "$FAKE/log"
wan stop 2>/dev/null
check "stop: pppd killed" no "$(yes_no kill -0 "$pid" 2>/dev/null)"
check "stop: VLAN removed" yes "$(yes_no has "$FAKE/log" "ip link del rnr0.835")"
check "stop: nft table removed" yes "$(yes_no has "$FAKE/log" "nft delete table inet gt_be98_wan")"
check "stop: rnr0 never touched" "" "$(grep -E '^ip link (del|set) rnr0( |$)' "$FAKE/log")"
# a VLAN device that existed before is not ours: never deleted
reset
mkdir -p "$T/net/rnr0.836"
printf 'WAN_VLAN=836\n' > "$T/etc/wan.conf"
wan start 2>/dev/null; wan stop 2>/dev/null
check "pre-existing VLAN kept" no "$(yes_no has "$FAKE/log" "ip link del rnr0.836")"
check "  control: created VLAN removed" yes "$(reset; printf 'WAN_VLAN=837\n' > "$T/etc/wan.conf"; wan start 2>/dev/null; wan stop 2>/dev/null; yes_no has "$FAKE/log" "ip link del rnr0.837")"
# MTU: WAN_MTU on the bare port; on a VLAN the port is raised first; PPPoE
# above 1492 sets the lower link to PPPOE_MTU + 8 (RFC 4638); every change is
# restored at stop, last first; the PPPoE default 1492 changes no MTU
mtus() { grep -E '^ip link set [^ ]+ mtu ' "$FAKE/log" | sed 's/^ip link set //' | tr '\n' '|' | sed 's/|$//'; }
reset; echo 1500 > "$T/net/rnr0/mtu"
printf 'WAN_MTU=9000\n' > "$T/etc/wan.conf"
wan start 2>/dev/null; a=$(mtus); : > "$FAKE/log"; wan stop 2>/dev/null
check "WAN_MTU=9000 on rnr0: set at start, 1500 back at stop" "rnr0 mtu 9000|rnr0 mtu 1500" "$a|$(mtus)"
reset; echo 1500 > "$T/net/rnr0/mtu"
printf 'WAN_VLAN=835\nWAN_MTU=9000\n' > "$T/etc/wan.conf"
wan start 2>/dev/null; a=$(mtus); : > "$FAKE/log"; wan stop 2>/dev/null
check "WAN_MTU=9000 on rnr0.835: the port raised first, then the VLAN; stop: the VLAN, then the port" \
	"rnr0 mtu 9000|rnr0.835 mtu 9000|rnr0.835 mtu 1500|rnr0 mtu 1500" "$a|$(mtus)"
reset; echo 9000 > "$T/net/rnr0/mtu"
printf 'WAN_VLAN=835\nWAN_MTU=9000\n' > "$T/etc/wan.conf"
wan start 2>/dev/null; a=$(mtus); wan stop 2>/dev/null
check "  control: the port already at 9000 is not touched" "rnr0.835 mtu 9000" "$a"
echo 1500 > "$T/net/rnr0/mtu"
reset; printf 'WAN_VLAN=835\nWAN_MTU=1400\n' > "$T/etc/wan.conf"
wan start 2>/dev/null; a=$(mtus); wan stop 2>/dev/null
check "  control: WAN_MTU=1400 on a VLAN lowers the VLAN only" "rnr0.835 mtu 1400" "$a"
reset; printf 'WAN_PROTO=pppoe\nWAN_VLAN=835\nPPPOE_USER=u\nPPPOE_MTU=1500\n' > "$T/etc/wan.conf"
wan start 2>/dev/null; a=$(mtus)
check "PPPOE_MTU=1500 on rnr0.835: port and VLAN at 1508, pppd mtu/mru 1500" "rnr0 mtu 1508|rnr0.835 mtu 1508 yes yes" \
	"$a $(yes_no grep -qx 'mtu 1500' "$FAKE/pppd.conf.seen") $(yes_no grep -qx 'mru 1500' "$FAKE/pppd.conf.seen")"
: > "$FAKE/log"; wan stop 2>/dev/null
check "  stop: 1500 back, VLAN first" "rnr0.835 mtu 1500|rnr0 mtu 1500" "$(mtus)"
reset; printf 'WAN_PROTO=pppoe\nPPPOE_USER=u\n' > "$T/etc/wan.conf"
wan start 2>/dev/null; a=$(mtus); wan stop 2>/dev/null
check "  control: PPPoE default 1492: no MTU change, pppd mtu 1492" "|yes" "$a|$(yes_no grep -qx 'mtu 1492' "$FAKE/pppd.conf.seen")"
# static on the bare port: dhcpcd's job, no nft, no input filter
reset
printf 'WAN_PROTO=static\nWAN_ADDR=192.0.2.10/24\nWAN_GW=192.0.2.1\n' > "$T/etc/wan.conf"
wan start 2>/dev/null
check "static on rnr0: no nft table" no "$(yes_no has "$FAKE/log" nft)"
check "static on rnr0: no address set by the tool (dhcpcd does it)" no "$(yes_no grep -q '^ip .*addr' "$FAKE/log")"
wan stop 2>/dev/null
# PD: forwarding on, RA dnsmasq, restored at stop
reset
printf 'WAN_IPV6=1\nWAN_PD_LANS="brwifi1 brwifi2"\n' > "$T/etc/wan.conf"
printf 'nameserver 192.0.2.53\nnameserver 2001:db8::53\n' > "$T/resolv.conf"
wan start 2>/dev/null
check "PD: forwarding on" yes "$(yes_no has "$FAKE/log" "sysctl -q -w net.ipv6.conf.all.forwarding=1")"
check "PD: RA constructor per LAN" "dhcp-range=::,constructor:brwifi1,ra-only,64,1h
dhcp-range=::,constructor:brwifi2,ra-only,64,1h" "$(grep '^dhcp-range' "$T/run/dnsmasq-ra.conf")"
check "PD: RA has no DHCP/DNS (port=0)" yes "$(yes_no grep -qx port=0 "$T/run/dnsmasq-ra.conf")"
check "PD: RDNSS = the WAN's v6 server only" "dhcp-option=option6:dns-server,[2001:db8::53]" "$(grep '^dhcp-option' "$T/run/dnsmasq-ra.conf")"
check "PD: v6 forward filter" yes "$(yes_no has "$T/run/wan.nft" 'iifname "rnr0" meta nfproto ipv6 drop')"
check "PD on the bare port: no input filter" no "$(yes_no has "$T/run/wan.nft" 'chain input')"
# dhcpcd hook: v6 policy routing of the LANs through the WAN's v6 gateway
echo "default via fe80::1 dev rnr0 proto ra metric 1003" > "$FAKE/route6-rnr0"
: > "$FAKE/log"
reason=ROUTERADVERT interface=rnr0 wan hook dhcpcd
check "hook: table 182 default via the WAN gw" yes "$(yes_no has "$FAKE/log" "ip -6 route replace default via fe80::1 dev rnr0 table 182")"
check "hook: rule per LAN" yes "$(yes_no has "$FAKE/log" "ip -6 rule add iif brwifi2 table 182 priority 182")"
: > "$FAKE/log"
reason=ROUTERADVERT interface=eth0 wan hook dhcpcd
check "  control: another interface's RA does nothing" "" "$(cat "$FAKE/log")"
rm -f "$FAKE/route6-rnr0"; : > "$FAKE/log"
reason=EXPIRE6 interface=rnr0 wan hook dhcpcd
check "hook: no v6 default = unreachable (never leaks)" yes "$(yes_no has "$FAKE/log" "ip -6 route replace unreachable default table 182")"
: > "$FAKE/log"
wan stop 2>/dev/null
check "stop: forwarding restored" yes "$(yes_no has "$FAKE/log" "sysctl -q -w net.ipv6.conf.all.forwarding=")"
check "stop: RA dnsmasq stopped" yes "$(yes_no grep -q 'start-stop-daemon --stop' "$FAKE/log")"

# ---- 5. trial / confirm / revert (management safety) ------------------------------------
reset
printf 'WAN_PROTO=static\nWAN_VLAN=835\nWAN_ADDR=192.0.2.10/24\nWAN_GW=192.0.2.1\n' > "$T/new.conf"
check "try: below 30 s refused" 1 "$(wan try 5 "$T/new.conf" >/dev/null 2>&1; echo $?)"
printf 'WAN_PROTO=bogus\n' > "$T/bad.conf"
check "try: invalid file refused" 1 "$(wan try 60 "$T/bad.conf" >/dev/null 2>&1; echo $?)"
check "  ... and nothing applied" no "$(yes_no test -f "$T/run/wan.trial.conf")"
wan try 60 "$T/new.conf" 2>/dev/null
check "try: trial active" "ifname=rnr0.835 config=trial" "$(wan status | grep -E '^(config|ifname)=' | tr '\n' ' ' | sed 's/ $//')"
check "try: saved config untouched" no "$(yes_no test -f "$T/etc/wan.conf")"
check "try: timer running" yes "$(yes_no kill -0 "$(cat "$T/run/trial.pid")" 2>/dev/null)"
check "try: dhcpcd rebinds the new VLAN only" "dhcpcd -n rnr0.835" "$(grep '^dhcpcd -n' "$FAKE/log")"
check "try: the management port rnr0 is never rebound for a VLAN WAN" no "$(yes_no grep -qE '^dhcpcd -n( .*)? rnr0( |$)' "$FAKE/log")"
left=$(wan status | sed -n 's/^trial_left=//p')
check "try: trial_left in 1..60" yes "$(yes_no test "$left" -ge 1 -a "$left" -le 60)"
tp=$(cat "$T/run/trial.pid")
wan confirm 2>/dev/null
check "confirm: saved" yes "$(yes_no cmp -s "$T/new.conf" "$T/etc/wan.conf")"
check "confirm: saved mode 600" 600 "$(stat -c %a "$T/etc/wan.conf")"
check "confirm: timer gone" no "$(yes_no kill -0 "$tp" 2>/dev/null)"
check "confirm: config=saved" config=saved "$(wan status | grep '^config=')"
printf 'WAN_PROTO=pppoe\nPPPOE_USER=u\n' > "$T/new2.conf"
wan try 60 "$T/new2.conf" 2>/dev/null
check "try 2: pppoe trial" ifname=pppoe-wan "$(wan status | grep '^ifname=')"
: > "$FAKE/log"
wan revert 2>/dev/null
check "revert: back on the saved config" "ifname=rnr0.835 config=saved" "$(wan status | grep -E '^(config|ifname)=' | tr '\n' ' ' | sed 's/ $//')"
check "revert: pppd gone, VLAN back" yes "$(yes_no has "$FAKE/log" "ip link add link rnr0 name rnr0.835 type vlan id 835")"
# the timer's own path (what fires after SECONDS)
wan try 60 "$T/new2.conf" 2>/dev/null
echo 1 > "$T/run/trial.deadline"	# the deadline has passed
wan revert --expired 2>/dev/null
check "expiry: reverted" config=saved "$(wan status | grep '^config=')"
check "expiry with no trial: rc 0" 0 "$(wan revert --expired >/dev/null 2>&1; echo $?)"
# a reboot during a trial: /run is empty, the saved config applies
wan try 60 "$T/new2.conf" 2>/dev/null
kill "$(cat "$T/run/trial.pid")" 2>/dev/null; wan stop 2>/dev/null
rm -rf "$T/run"; mkdir -p "$T/run"
check "reboot mid-trial: saved config" "ifname=rnr0.835 config=saved" "$(wan status | grep -E '^(config|ifname)=' | tr '\n' ' ' | sed 's/ $//')"

# ---- 5b. which interfaces dhcpcd rebinds (only a changed block) --------------
reset
printf 'WAN_VLAN=835\n' > "$T/v.conf"
wan try 60 "$T/v.conf" 2>/dev/null
: > "$FAKE/log"
wan revert 2>/dev/null
check "revert of a VLAN WAN: no dhcpcd rebind at all (rnr0 untouched)" "" "$(grep '^dhcpcd' "$FAKE/log")"
printf 'WAN_PROTO=static\nWAN_ADDR=192.0.2.10/24\nWAN_GW=192.0.2.1\n' > "$T/s.conf"
: > "$FAKE/log"
wan try 60 "$T/s.conf" 2>/dev/null
check "  control: a static WAN on bare rnr0 rebinds rnr0" "dhcpcd -n rnr0" "$(grep '^dhcpcd -n' "$FAKE/log")"
: > "$FAKE/log"
wan revert 2>/dev/null
check "  control: and its revert rebinds rnr0 again" "dhcpcd -n rnr0" "$(grep '^dhcpcd -n' "$FAKE/log")"

# ---- 5c. the deadline: token, watcher, a timer that outlives its caller ------
reset
printf 'WAN_VLAN=835\n' > "$T/v.conf"
wan try 60 "$T/v.conf" 2>/dev/null
d=$(cat "$T/run/trial.deadline")
wan revert --expired 2>/dev/null
check "revert --expired before the deadline: no-op" config=trial "$(wan status | grep '^config=')"
echo 1 > "$T/run/trial.deadline"
wan revert --expired "$d" 2>/dev/null
check "revert --expired with another trial's token: no-op" config=trial "$(wan status | grep '^config=')"
wan revert --expired 1 2>/dev/null
check "  control: this trial's token, deadline passed: reverted" config=default "$(wan status | grep '^config=')"
# the watcher alone (the trial's own timer killed, as if its caller's session took it)
wan try 60 "$T/v.conf" 2>/dev/null
kill "$(cat "$T/run/trial.pid")" 2>/dev/null
WATCH_INTERVAL=1 $SH "$W" watch </dev/null >/dev/null 2>&1 &
wp=$!
sleep 3
check "watcher: does nothing before the deadline" config=trial "$(wan status | grep '^config=')"
echo 1 > "$T/run/trial.deadline"
n2=0; while [ $n2 -lt 10 ] && { [ "$(wan status | grep '^config=')" = config=trial ] || [ -e "$T/net/rnr0.835" ]; }; do sleep 1; n2=$((n2 + 1)); done
check "watcher: reverts a due trial whose timer is dead" config=default "$(wan status | grep '^config=')"
check "  ... and its VLAN is gone" no "$(yes_no test -e "$T/net/rnr0.835")"
kill $wp 2>/dev/null; wait $wp 2>/dev/null
# the one-shot timer survives the end of its caller's process group (setsid)
if command -v setsid >/dev/null 2>&1; then
	printf 'WAN_VLAN=835\n' > "$T/v.conf"
	setsid $SH -c "$SH '$W' try 30 '$T/v.conf' >/dev/null 2>&1" ; sleep 1
	tp=$(cat "$T/run/trial.pid"); kill -0 "$tp" 2>/dev/null && pg=$(ps -o pgid= -p "$tp" | tr -d ' ')
	check "timer: alive after its caller exited, in its own process group" yes "$(yes_no test -n "${pg:-}" -a "${pg:-0}" = "$tp")"
	wan revert 2>/dev/null
fi

# ---- 5d. pppd: found by its pid file and by its option file ------------------
reset
printf 'WAN_PROTO=pppoe\nPPPOE_USER=u\n' > "$T/etc/wan.conf"
wan start 2>/dev/null
pp=$(head -n1 "$T/run/ppp-wan.pid")
mkdir -p "$T/stray"; printf '#!/bin/sh\nwhile :; do sleep 1; done\n' > "$T/stray/pppd"; chmod +x "$T/stray/pppd"
"$T/stray/pppd" file "$T/run/pppd.conf" </dev/null >/dev/null 2>&1 & sp=$!
sleep 1
rm -f "$T/run/applied"	# a lost record: stop must still find both
wan stop 2>/dev/null
check "stop: the recorded pppd is gone" no "$(yes_no kill -0 "$pp" 2>/dev/null)"
check "stop: a stray pppd on our option file is gone" no "$(yes_no kill -0 "$sp" 2>/dev/null)"
"$T/stray/pppd" file /elsewhere/pppd.conf </dev/null >/dev/null 2>&1 & op=$!
sleep 1; wan stop 2>/dev/null
check "  control: a pppd on another option file is left alone" yes "$(yes_no kill -0 "$op" 2>/dev/null)"
kill $op 2>/dev/null
# the default pid-file path is the one the image's pppd writes (PPPD_BIN=<target>/usr/sbin/pppd)
if [ -n "${PPPD_BIN:-}" ]; then
	rd=$(strings "$PPPD_BIN" | grep -x '/var/run/pppd\|/run/pppd' | head -n1)
	td=$(env -u PPP_RUNDIR $SH -c ". /dev/null; sed -n 's/^ppp_pidfile() { echo \"\${PPP_RUNDIR:-\(.*\)}\/ppp-wan.pid\"; }$/\\1/p' '$W'")
	check "pid dir: the tool's default = the built pppd's runtime dir (/var/run -> /run)" "$rd" "/var$td"
fi

# ---- 6. pppd hooks: DNS into resolv.conf, out again ---------------------------------------
reset
printf 'nameserver 10.9.9.9\n' > "$T/resolv/eth0.dhcp"
DNS1=192.0.2.53 DNS2=192.0.2.54 wan hook ip-up pppoe-wan /dev/null 0 100.64.0.2 100.64.0.1 wan 2>/dev/null
check "ip-up: PPP DNS in resolv.conf" "nameserver 10.9.9.9
nameserver 192.0.2.53
nameserver 192.0.2.54" "$(grep '^nameserver' "$T/resolv.conf")"
DNS1='1.2.3.4;reboot' wan hook ip-up pppoe-wan 2>/dev/null
check "ip-up: a bogus DNS value is dropped" "nameserver 10.9.9.9" "$(grep '^nameserver' "$T/resolv.conf")"
wan hook ip-down pppoe-wan 2>/dev/null
check "ip-down: PPP DNS gone" "nameserver 10.9.9.9" "$(grep '^nameserver' "$T/resolv.conf")"

# ---- 6b. the PPP fragment lives in dhcpcd's OWN fragment directory --------------------------
# (wan-arms W2 on img28: session up, 192.0.2.53 absent from /etc/resolv.conf. The tool wrote
# /run/dhcpcd/resolv.conf/, dhcpcd 10.2.4 merges $state_dir/resolv.conf/ =
# /var/run/dhcpcd/hook-state/resolv.conf/: each side's rebuild dropped the other's servers.)
# Here: no DHCPCD_RESOLV_DIR override, the directory comes from the hook runner's state_dir,
# and /etc/resolv.conf is a symlink as on the image (-> /run/resolv.conf).
reset
mkdir -p "$T/hs/resolv.conf"
printf '#!/bin/sh\nstate_dir=%s\n' "$T/hs" > "$T/run-hooks"
printf 'nameserver 10.9.9.9\n' > "$T/hs/resolv.conf/rnr0.dhcp"
rm -rf "$T/resolv/"*; rm -f "$T/resolv.conf"; : > "$T/run-resolv.conf"; ln -s "$T/run-resolv.conf" "$T/resolv.conf"
hk() { env -u DHCPCD_RESOLV_DIR DHCPCD_RUN_HOOKS="$T/run-hooks" $SH "$W" "$@"; }
(umask 077; DNS1=192.0.2.53 hk hook ip-up pppoe-wan /dev/null 0 100.64.0.2 100.64.0.1 wan 2>/dev/null)
check "ip-up: the PPP fragment is in dhcpcd's \$state_dir/resolv.conf" yes "$(yes_no grep -qx 'nameserver 192.0.2.53' "$T/hs/resolv.conf/pppoe-wan.ppp")"
check "  control: nothing written to the override directory" no "$(yes_no test -e "$T/resolv/pppoe-wan.ppp")"
check "ip-up: dhcpcd's server kept, the PPP one after it" "nameserver 10.9.9.9
nameserver 192.0.2.53" "$(grep '^nameserver' "$T/run-resolv.conf")"
check "ip-up: /etc/resolv.conf is still the symlink (written through it)" yes "$(yes_no test -L "$T/resolv.conf")"
check "ip-up: resolv.conf 644 although pppd runs the hook with umask 077" 644 "$(stat -c %a "$T/run-resolv.conf")"
# what dhcpcd's 20-resolv.conf does at its next rebuild: every fragment of its directory
check "a dhcpcd rebuild (all of \$state_dir/resolv.conf/*) keeps the PPP DNS" yes \
	"$(yes_no sh -c "cat '$T/hs/resolv.conf/'* | grep -qx 'nameserver 192.0.2.53'")"
# a PPPoE trial, then revert: the PPP DNS goes, the management (dhcpcd) DNS stays
printf 'WAN_PROTO=pppoe\nPPPOE_USER=u\n' > "$T/p.conf"
hk try 60 "$T/p.conf" 2>/dev/null
DNS1=192.0.2.53 hk hook ip-up pppoe-wan 2>/dev/null
check "trial: PPP DNS in" yes "$(yes_no grep -qx 'nameserver 192.0.2.53' "$T/run-resolv.conf")"
hk revert 2>/dev/null
check "revert: PPP DNS gone, dhcpcd's kept" "nameserver 10.9.9.9" "$(grep '^nameserver' "$T/run-resolv.conf")"
check "revert: the PPP fragment removed" no "$(yes_no test -e "$T/hs/resolv.conf/pppoe-wan.ppp")"
check "revert: /etc/resolv.conf still the symlink" yes "$(yes_no test -L "$T/resolv.conf")"
# against the image's dhcpcd (DHCPCD_HOOKS=<target>/lib/dhcpcd/dhcpcd-run-hooks): its
# 20-resolv.conf merges "$state_dir/resolv.conf", the directory the tool derives
if [ -n "${DHCPCD_HOOKS:-}" ]; then
	td=$(DHCPCD_RUN_HOOKS="$DHCPCD_HOOKS" $SH -c "$(sed -n '/^dhcpcd_resolv_dir() {/,/^}/p' "$W"); dhcpcd_resolv_dir")
	check "built dhcpcd: 20-resolv.conf merges \$state_dir/resolv.conf" yes \
		"$(yes_no grep -qx 'resolv_conf_dir="$state_dir/resolv.conf"' "$(dirname "$DHCPCD_HOOKS")/dhcpcd-hooks/20-resolv.conf")"
	check "built dhcpcd: the tool's fragment dir = its state_dir/resolv.conf" \
		"$(sed -n 's/^state_dir=//p' "$DHCPCD_HOOKS")/resolv.conf" "$td"
	check "  ... and not the old fixed /run/dhcpcd/resolv.conf" no "$(yes_no test "$td" = /run/dhcpcd/resolv.conf)"
fi

# ---- 7. integration: gt-be98-router follows the WAN ----------------------------------------
reset
printf 'WAN_PROTO=pppoe\nPPPOE_USER=u\n' > "$T/etc/wan.conf"
mkdir -p "$T/router"
printf 'ROUTER_WAN="wan"\nROUTER_LANS="bcawl3=192.168.83.1/24"\n' > "$T/router/router.conf"
echo "default dev pppoe-wan scope link metric 4000" > "$FAKE/route4-pppoe-wan"
r=$( (
	eerror() { echo "E $*"; }; ebegin() { :; }; eend() { :; }; ewarn() { echo "W $*"; }
	ROUTER_DIR="$T/router" GT_BE98_WAN="$SH $W" ROUTER_TABLE=180
	. "$SRC/init.d/gt-be98-router"
	load_conf && echo "wan=$ROUTER_WAN" && route_table
) 2>&1 )
check "router: ROUTER_WAN=wan resolves to the PPPoE netdev" yes "$(yes_no grep -qx wan=pppoe-wan <<EOF
$r
EOF
)"
check "router: point-to-point default into table 180" yes "$(yes_no has "$FAKE/log" "ip route replace default dev pppoe-wan table 180")"
check "router: no 'unreachable' when the p2p default exists" no "$(yes_no has "$FAKE/log" "unreachable default table 180")"
rm -f "$FAKE/route4-pppoe-wan"; : > "$FAKE/log"
( eerror() { :; }; ebegin() { :; }; eend() { :; }; ewarn() { :; }
  ROUTER_DIR="$T/router" GT_BE98_WAN="$SH $W" ROUTER_TABLE=180
  . "$SRC/init.d/gt-be98-router"; load_conf && route_table ) >/dev/null 2>&1
check "  control: no default on the WAN = unreachable" yes "$(yes_no has "$FAKE/log" "ip route replace unreachable default table 180")"
printf 'WAN_PROTO=bogus\n' > "$T/etc/wan.conf"
check "router: ROUTER_WAN=wan with an invalid WAN config refused" 1 "$( (
	eerror() { :; }; ebegin() { :; }; eend() { :; }; ewarn() { :; }
	ROUTER_DIR="$T/router" GT_BE98_WAN="$SH $W"
	. "$SRC/init.d/gt-be98-router"; load_conf ) >/dev/null 2>&1; echo $?)"

# ---- 8. D22: router mode implies an input firewall on its WAN ------------------------------
# the rule set is gt-be98-wan's VLAN/PPPoE input chain, the same lines
reset
printf 'WAN_PROTO=pppoe\nPPPOE_USER=u\n' > "$T/etc/wan.conf"
wan start 2>/dev/null; wan stop 2>/dev/null
sed -n '/chain input/,/^[[:space:]]*}$/p' "$T/run/wan.nft" | sed 's/"pppoe-wan"/"IF"/' > "$T/in.wan"
$SH "$W" input-nft gt_be98_router_in rnr0 > "$T/in.nft" 2>/dev/null; r=$?
check "input-nft rnr0: exit 0" 0 $r
check "input-nft: the VLAN/PPPoE WAN's own input chain, on rnr0" "$(cat "$T/in.wan")" \
	"$(sed -n '/chain input/,/^[[:space:]]*}$/p' "$T/in.nft" | sed 's/"rnr0"/"IF"/')"
check "  control: the PPPoE chain was read (it drops)" yes "$(yes_no grep -q 'iifname "IF" drop' "$T/in.wan")"
check "input-nft: one table inet, replaced atomically" "table inet gt_be98_router_in {}|delete table inet gt_be98_router_in|table inet gt_be98_router_in {" \
	"$(head -n3 "$T/in.nft" | tr '\n' '|' | sed 's/|$//')"
$SH "$W" input-nft gt_be98_router_in rnr0 192.0.2.0/24 2001:db8::/64 198.51.100.7/32 > "$T/in2.nft" 2>/dev/null
check "input-nft allow-list: v4 and v6 accepts after DHCP, before the drop" \
	'iifname "rnr0" udp dport { 68, 546 } accept|iifname "rnr0" ip saddr { 192.0.2.0/24, 198.51.100.7/32 } accept|iifname "rnr0" ip6 saddr { 2001:db8::/64 } accept|iifname "rnr0" drop' \
	"$(grep -E 'udp dport|saddr|drop' "$T/in2.nft" | sed 's/^[[:space:]]*//' | tr '\n' '|' | sed 's/|$//')"
check "input-nft without an allow-list: no saddr rule" no "$(yes_no grep -q saddr "$T/in.nft")"
for bad in '192.0.2.0' '192.0.2.0/33' '300.0.2.0/24' '2001:db8::/129' 'x;drop/24' ''; do
	check "input-nft refuses allow '$bad'" 1 "$($SH "$W" input-nft t rnr0 "$bad" >/dev/null 2>&1; echo $?)"
done
check "  control: 0.0.0.0/0 and ::/0 accepted" 0 "$($SH "$W" input-nft t rnr0 0.0.0.0/0 ::/0 >/dev/null 2>&1; echo $?)"
check "input-nft refuses interface 'rnr0 }'" 1 "$($SH "$W" input-nft t 'rnr0 }' >/dev/null 2>&1; echo $?)"
check "input-nft refuses table 'a b'" 1 "$($SH "$W" input-nft 'a b' rnr0 >/dev/null 2>&1; echo $?)"
check "input-nft refuses a missing interface" 1 "$($SH "$W" input-nft t >/dev/null 2>&1; echo $?)"
# --igmp (router mode's igmpproxy): IGMP accepted after DHCP, before the allow-list and the drop
$SH "$W" input-nft gt_be98_router_in rnr0 --igmp 192.0.2.0/24 > "$T/in3.nft" 2>/dev/null; r=$?
check "input-nft --igmp: rc 0, IGMP accepted after DHCP, then the allow-list, then the drop" \
	'0|iifname "rnr0" udp dport { 68, 546 } accept|iifname "rnr0" meta l4proto igmp accept|iifname "rnr0" ip saddr { 192.0.2.0/24 } accept|iifname "rnr0" drop' \
	"$r|$(grep -E 'udp dport|igmp|saddr|drop' "$T/in3.nft" | sed 's/^[[:space:]]*//' | tr '\n' '|' | sed 's/|$//')"
check "  control: without --igmp no IGMP rule (in.nft, in2.nft)" "no no" "$(yes_no grep -q igmp "$T/in.nft") $(yes_no grep -q igmp "$T/in2.nft")"
check "  --igmp is not taken for a CIDR (refused only as one)" 1 "$($SH "$W" input-nft t rnr0 192.0.2.0/24 --igmp >/dev/null 2>&1; echo $?)"
# the service: router mode on the bare uplink loads the filter BEFORE NAT and
# forwarding; a filter that cannot be built keeps router mode down
rsrc() {	# the router service's functions, its run files under $T
	eerror() { echo "E $*"; }; ebegin() { :; }; eend() { [ "${1:-0}" = 0 ] || echo "E $*"; return "${1:-0}"; }; ewarn() { :; }
	ROUTER_DIR="$T/router" GT_BE98_WAN="$SH $W" ROUTER_TABLE=180 ROUTER_INPUT_NFT="$T/router-in.nft"
	. "$SRC/init.d/gt-be98-router"
	APPLIED=$T/router.applied DNSMASQ_PID=$T/router-dnsmasq.pid IFACE_WAIT=0
	IGMPPROXY=$T/bin/igmpproxy IGMPPROXY_CONF=$T/igmpproxy.conf IGMPPROXY_PID=$T/igmpproxy.pid
}
rstart() { ( rsrc; start; echo "rc=$?" ); }
isrc() { printf '%s\n' "$1" | grep -qx "$2" && echo yes || echo no; }
reset; rm -f "$T/etc/wan.conf"
printf 'ROUTER_WAN="rnr0"\nROUTER_LANS="bcawl3=192.168.83.1/24"\nROUTER_WAN_ALLOW="192.0.2.0/24"\n' > "$T/router/router.conf"
r=$(rstart 2>&1)
check "router start on rnr0: rc 0" yes "$(isrc "$r" rc=0)"
check "router: input filter checked, loaded, then router.nft, then forwarding" \
	"nft -c -f $T/router-in.nft|nft -f $T/router-in.nft|nft -c -f $T/router/router.nft|nft -f $T/router/router.nft|sysctl -q -w net.ipv4.ip_forward=1" \
	"$(grep -E '^(nft|sysctl)' "$FAKE/log" | tr '\n' '|' | sed 's/|$//')"
check "router: the filter is on rnr0, with the allow-list" yes "$(yes_no grep -q 'iifname "rnr0" ip saddr { 192.0.2.0/24 } accept' "$T/router-in.nft")"
check "router: the filter drops the rest of rnr0's input" yes "$(yes_no grep -q 'iifname "rnr0" drop' "$T/router-in.nft")"
reset
printf 'ROUTER_WAN="rnr0"\nROUTER_LANS="bcawl3=192.168.83.1/24"\nROUTER_WAN_ALLOW="192.0.2.0"\n' > "$T/router/router.conf"
r=$(rstart 2>&1)
check "router: a bad allow-list CIDR = router mode not started (rc 1)" yes "$(isrc "$r" rc=1)"
check "  ... no NAT loaded, no forwarding turned on" "" "$(grep -E 'router.nft|ip_forward=1' "$FAKE/log")"
reset
printf 'ROUTER_WAN="rnr0"\nROUTER_LANS="bcawl3=192.168.83.1/24"\nROUTER_WAN_ALLOW="192.0.2.0/24 *"\n' > "$T/router/router.conf"
r=$(rstart 2>&1)
check "router: an allow-list with a non-CIDR character refused (rc 1, no NAT)" "yes " "$(isrc "$r" rc=1) $(grep -E 'router.nft|ip_forward=1' "$FAKE/log")"
reset
printf 'ROUTER_WAN="rnr0"\nROUTER_LANS="bcawl3=192.168.83.1/24"\n' > "$T/router/router.conf"
r=$(rstart 2>&1)
check "router: no allow-list = rc 0, filter without saddr, NAT and forwarding on" "yes no yes" \
	"$(isrc "$r" rc=0) $(yes_no grep -q saddr "$T/router-in.nft") $(yes_no has "$FAKE/log" 'net.ipv4.ip_forward=1')"
reset
( rsrc; stop ) >/dev/null 2>&1
check "router stop: the input filter table is removed" yes "$(yes_no has "$FAKE/log" "nft delete table inet gt_be98_router_in")"
# reroute follows ROUTER_WAN="wan": the WAN netdev changes, the filter with it
reset
printf 'WAN_VLAN=835\n' > "$T/etc/wan.conf"
printf 'ROUTER_WAN="wan"\nROUTER_LANS="bcawl3=192.168.83.1/24"\n' > "$T/router/router.conf"
( rsrc; reroute ) >/dev/null 2>&1
check "router reroute: the filter re-applied on the WAN netdev (rnr0.835)" "yes yes" \
	"$(yes_no has "$FAKE/log" "nft -f $T/router-in.nft") $(yes_no grep -q 'iifname "rnr0.835" drop' "$T/router-in.nft")"
# multicast routing (ROUTER_IGMP_PROXY=1): IGMP on the WAN input, igmpproxy
# with the WAN upstream and the router LANs that exist downstream; not
# started while the WAN has no IPv4 address; off by default
printf '#!/bin/sh\nexit 0\n' > "$T/bin/igmpproxy"; chmod +x "$T/bin/igmpproxy"
mkdir -p "$T/net/bcawl3"
reset; rm -f "$T/etc/wan.conf"
printf 'ROUTER_WAN="rnr0"\nROUTER_LANS="bcawl3=192.168.83.1/24 bcawl0=192.168.80.1/24"\n' > "$T/router/router.conf"
echo "2: rnr0    inet 198.51.100.2/24 brd 198.51.100.255 scope global rnr0" > "$FAKE/addr4-rnr0"
r=$( ( rsrc; ROUTER_IGMP_PROXY=1; start; echo "rc=$?" ) 2>&1)
check "router + ROUTER_IGMP_PROXY=1: rc 0, IGMP accepted on the WAN input" "yes yes" "$(isrc "$r" rc=0) $(yes_no grep -q 'iifname "rnr0" meta l4proto igmp accept' "$T/router-in.nft")"
check "  igmpproxy started in the foreground under start-stop-daemon, with its config" yes \
	"$(yes_no has "$FAKE/log" "start-stop-daemon --start --background --make-pidfile --pidfile $T/igmpproxy.pid --exec $T/bin/igmpproxy -- -n $T/igmpproxy.conf")"
check "  its config: quickleave, rnr0 upstream (altnet 0.0.0.0/0), the existing LAN bcawl3 downstream (bcawl0 absent)" \
	"quickleave|phyint rnr0 upstream ratelimit 0 threshold 1|altnet 0.0.0.0/0|phyint bcawl3 downstream ratelimit 0 threshold 1" \
	"$(grep -v '^#' "$T/igmpproxy.conf" | sed 's/^[[:space:]]*//' | tr '\n' '|' | sed 's/|$//')"
reset; rm -f "$FAKE/addr4-rnr0" "$T/igmpproxy.conf"
r=$( ( rsrc; ROUTER_IGMP_PROXY=1; start; echo "rc=$?" ) 2>&1)
check "  the WAN without an IPv4 address: router rc 0, no igmpproxy yet (its lease's reroute starts it)" "yes no no" \
	"$(isrc "$r" rc=0) $(yes_no grep -q igmpproxy "$FAKE/log") $(yes_no test -f "$T/igmpproxy.conf")"
echo "2: rnr0    inet 198.51.100.2/24 brd 198.51.100.255 scope global rnr0" > "$FAKE/addr4-rnr0"
reset; ( rsrc; ROUTER_IGMP_PROXY=1; reroute ) >/dev/null 2>&1
check "  reroute with the lease: igmpproxy started" yes "$(yes_no grep -q "start-stop-daemon --start .*igmpproxy" "$FAKE/log")"
reset; echo 1 > "$T/igmpproxy.pid"; ( rsrc; stop ) >/dev/null 2>&1
check "  stop: igmpproxy stopped (its pid file), its config removed" "yes no no" \
	"$(yes_no grep -q "start-stop-daemon --stop --exec $T/bin/igmpproxy --pidfile $T/igmpproxy.pid" "$FAKE/log") $(yes_no test -f "$T/igmpproxy.pid") $(yes_no test -f "$T/igmpproxy.conf")"
reset; r=$( ( rsrc; start; echo "rc=$?" ) 2>&1)
check "  control: ROUTER_IGMP_PROXY unset (the default 0): no IGMP rule, no igmpproxy" "yes no no" \
	"$(isrc "$r" rc=0) $(yes_no grep -q igmp "$T/router-in.nft") $(yes_no grep -q igmpproxy "$FAKE/log")"
rm -f "$FAKE/addr4-rnr0"; rm -rf "$T/net/bcawl3"
# AP mode: nothing in the WAN tool filters the bare uplink (rnr0 = management)
reset; rm -f "$T/etc/wan.conf"
wan start 2>/dev/null
check "AP mode (default WAN, no router): no nft at all, rnr0 unfiltered" "" "$(grep '^nft' "$FAKE/log")"
wan stop 2>/dev/null

echo "gt-be98-wan-test ($SH): $((n - fail))/$n ok"
[ $fail -eq 0 ] && echo "all passed"
[ $fail -eq 0 ]

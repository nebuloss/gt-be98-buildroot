#!/bin/sh
# shellcheck shell=busybox
# SPDX-License-Identifier: GPL-2.0
# Offline test of sbin/gt-be98-wifi-sta (no device, no root):
#   sh test/gt-be98-wifi-sta-test.sh
# Every tool it drives is a fake that logs its command line to $T/log
# (wpa_cli answers from $T/wpa-state-<dev>, start-stop-daemon runs nothing);
# the checks are on those commands and on the files the helper writes. Runs
# with SH=sh (default), dash or bash. Not with "busybox sh": it runs its own
# ip/sysctl/start-stop-daemon applets before PATH, so the fakes would not be
# reached (the helper is executed, not sourced: no function can stand in);
# the image has no busybox at all (/bin/sh is bash), so nothing is lost.
set -u
case "${SH:-sh}" in *busybox*) echo "skip: SH=$SH (busybox applets shadow the fakes, see the header)"; exit 0 ;; esac
here=$(cd "$(dirname "$0")" && pwd)
H="$here/../src/sbin/gt-be98-wifi-sta"
T=$(mktemp -d)
# the fakes' sleepers are found by their pid files
trap 'for f in $(find "$T" -name "*.pid"); do kill "$(cat "$f")" 2>/dev/null; done; rm -rf "$T"' EXIT
fail=0 n=0
check() {
	n=$((n + 1))
	if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want [$2] got [$3]"; fail=1; fi
}
mkdir -p "$T/bin"
for t in nft sysctl logger rc-service hostapd_cli; do
	printf '#!/bin/sh\necho "%s $*" >> "$FAKE/log"\nexit 0\n' "$t" > "$T/bin/$t"
done
# iw: keeps each netdev's 4-address mode (set 4addr on|off) and reports it (info)
cat > "$T/bin/iw" <<'X'
#!/bin/sh
echo "iw $*" >> "$FAKE/log"
[ "$1 $3 $4" = "dev set 4addr" ] && echo "$5" > "$FAKE/4addr-$2"
[ "$1 $3" = "dev info" ] && [ "$(cat "$FAKE/4addr-$2" 2>/dev/null)" = on ] && printf '\t4addr: on\n'
exit 0
X
# ip: a bridge port is the netdev's master link (link set dev X master B / nomaster)
cat > "$T/bin/ip" <<'X'
#!/bin/sh
echo "ip $*" >> "$FAKE/log"
if [ "$1 $2 $3" = "link set dev" ]; then
	case "$5" in
	master) mkdir -p "$FAKE/net/$4"; ln -sfn "../$6" "$FAKE/net/$4/master" ;;
	nomaster) rm -f "$FAKE/net/$4/master" ;;
	esac
fi
exit 0
X
# dnsmasq: daemonizes (a sleeper) and writes the pid-file= of its config
cat > "$T/bin/dnsmasq" <<'X'
#!/bin/sh
echo "dnsmasq $*" >> "$FAKE/log"
c=${1#--conf-file=}
sleep 1000 & echo $! > "$(sed -n 's/^pid-file=//p' "$c")"
exit 0
X
# nft -c refuses a file holding the word REFUSE (the two-way control)
cat > "$T/bin/nft" <<'X'
#!/bin/sh
echo "nft $*" >> "$FAKE/log"
[ "$1" = -c ] && grep -q REFUSE "$3" && exit 1
exit 0
X
cat > "$T/bin/wpa_cli" <<'X'
#!/bin/sh
d=; while [ $# -gt 0 ]; do case $1 in -p) shift 2 ;; -i) d=$2; shift 2 ;; *) break ;; esac; done
echo "wpa_cli $d $*" >> "$FAKE/log"
case "$1" in
status) cat "$FAKE/wpa-state-$d" 2>/dev/null ;;
reconfigure) cat "$FAKE/reconf" 2>/dev/null || echo OK ;;
esac
exit 0
X
cat > "$T/bin/wpa_supplicant" <<'X'
#!/bin/sh
echo "wpa_supplicant $*" >> "$FAKE/log"
p=; while [ $# -gt 0 ]; do [ "$1" = -P ] && p=$2; shift; done
sleep 1000 & echo $! > "$p"
[ -f "$FAKE/assoc" ] && cp "$FAKE/assoc" "$FAKE/wpa-state-bcawl0"
exit 0
X
cat > "$T/bin/start-stop-daemon" <<'X'
#!/bin/sh
echo "ssd $*" >> "$FAKE/log"
case " $* " in
*" --start "*) pf=; while [ $# -gt 0 ]; do [ "$1" = --pidfile ] && pf=$2; shift; done
	sleep 1000 & echo $! > "$pf" ;;
*" --stop "*) pf=; while [ $# -gt 0 ]; do [ "$1" = --pidfile ] && pf=$2; shift; done
	kill "$(cat "$pf")" 2>/dev/null ;;
esac
exit 0
X
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" FAKE="$T" GT_BE98_RUN="$T/run" GT_BE98_SYSNET="$T/net" \
	GT_BE98_CONFD="$T/confd" GT_BE98_LOGDIR="$T/logs"
mkdir -p "$T/run/gt-be98-wifi" "$T/net/bcawl0" "$T/net/brwifi50/bridge" "$T/net/brwifi60/bridge"
: > "$T/confd"
S="$T/run/gt-be98-wifi/sta"; D="$T/run/gt-be98-wifi/sta-dns"
run() { : > "$T/log"; ${SH:-sh} "$H" "$@" > "$T/out" 2>&1; rc=$?; }
log() { grep -E "$1" "$T/log" | tr '\n' '|' | sed 's/|$//'; }
assoc() { printf 'bssid=02:00:5e:00:53:01\nfreq=%s\nssid=up\nwpa_state=COMPLETED\nkey_mgmt=WPA2-PSK\n' "$1"; }

# ---- freq ----
assoc 5180 > "$T/wpa-state-bcawl0"; run freq bcawl0
check "freq: associated" "0 5180" "$rc $(cat "$T/out")"
printf 'wpa_state=SCANNING\nfreq=5180\n' > "$T/wpa-state-bcawl0"; run freq bcawl0
check "freq: not associated, exit 1, nothing printed" "1 " "$rc $(cat "$T/out")"
run freq eth0
check "freq eth0: refused" 1 "$rc"

# ---- up: a new station waits for its association ----
printf 'ctrl_interface=/run/wpa_supplicant\nnetwork={\n\tssid=7570\n}\n' > "$T/sta.conf"
rm -f "$T/wpa-state-bcawl0"; assoc 5200 > "$T/assoc"
echo 'STA_WAIT=3' > "$T/confd"
run up bcawl0 "$T/sta.conf" sum1
check "up: managed, up, wpa_supplicant -B on bcawl0 with the config" \
	"0 iw dev bcawl0 set type managed|ip link set dev bcawl0 up|wpa_supplicant -B -i bcawl0 -c $T/sta.conf -P $S/bcawl0.wpa.pid -f $T/logs/wpa_supplicant-bcawl0.log" \
	"$rc $(log '^(iw dev bcawl0 set|ip link|wpa_supplicant)')"
cp "$T/log" "$T/log.first"
check "up: the DHCP client in its own mount namespace, never through the manager" \
	"/usr/bin/unshare -- -m /bin/sh -c|mount --bind \"\$1\" /var/run/dhcpcd|-c \"\$3\" -4 \"\$4\"|$S/dhcpcd-bcawl0 $S/bcawl0.dhcpcd.conf" \
	"$(grep -o '/usr/bin/unshare -- -m /bin/sh -c' "$T/log")|$(grep -o 'mount --bind "$1" /var/run/dhcpcd' "$T/log")|$(grep -o '\-c "$3" -4 "$4"' "$T/log")|$(grep -o "$S/dhcpcd-bcawl0 $S/bcawl0.dhcpcd.conf" "$T/log")"
check "up: dhcpcd config: only bcawl0, no gateway of its own, never gives up" "allowinterfaces bcawl0|nogateway|timeout 0" \
	"$(grep -E '^(allowinterfaces|nogateway|timeout)' "$S/bcawl0.dhcpcd.conf" | tr '\n' '|' | sed 's/|$//')"
check "up: waited for COMPLETED (status polled), state 0700, sum kept" "yes drwx------ sum1" \
	"$(grep -q 'wpa_cli bcawl0 status' "$T/log" && echo yes || echo no) $(ls -ld "$S" | cut -c1-10) $(cat "$S/bcawl0.sum")"
rm -f "$T/assoc"
run up bcawl0 "$T/sta.conf" sum1
check "up again, same config: nothing restarted, nothing re-read" "0 ||" "$rc $(log '^wpa_supplicant')|$(log 'reconfigure')|$(log 'ssd .*--start')"
run up bcawl0 "$T/sta.conf" sum2
check "up, config changed: wpa_cli reconfigure, the process kept" "0 wpa_cli bcawl0 reconfigure|" "$rc $(log 'reconfigure')|$(log '^wpa_supplicant')"
echo FAIL > "$T/reconf"; run up bcawl0 "$T/sta.conf" sum3; rm -f "$T/reconf"
check "up, reconfigure refused: restarted" "0 yes" "$rc $(log '^wpa_supplicant' | grep -q -- '-i bcawl0' && echo yes || echo no)"
run up bcawl0 "$T/sta.conf" sum3 restart
check "up restart (an AP interface appeared): stopped, started again" "0 yes yes" \
	"$rc $(log 'ssd --stop --pidfile '"$S"'/bcawl0.wpa.pid' | grep -q . && echo yes || echo no) $(log '^wpa_supplicant' | grep -q . && echo yes || echo no)"
run up bcawl0 /nonexistent sum
check "up, no config: refused" 1 "$rc"

# ---- the DHCP client's script ----
echo bcawl0 > "$T/run/gt-be98-wifi/stations"
dhcp() {	# reason [extra env]
	: > "$T/log"
	env reason="$1" interface=bcawl0 new_ip_address=192.0.2.20 new_subnet_cidr=24 \
		new_network_number=192.0.2.0 new_routers="192.0.2.1 192.0.2.254" \
		new_domain_name_servers="192.0.2.53 198.51.100.53" ${SH:-sh} "$H" > "$T/out" 2>&1
	rc=$?
}
: > "$T/run/gt-be98-wifi/routed"
dhcp BOUND
check "BOUND: lease, default via the first router at metric 3000, resolv for dnsmasq" \
	"0 ip=192.0.2.20/24 net=192.0.2.0/24 gw=192.0.2.1|ip route replace default via 192.0.2.1 dev bcawl0 metric 3000|nameserver 192.0.2.53 nameserver 198.51.100.53" \
	"$rc $(tr '\n' ' ' < "$S/bcawl0.lease" | sed 's/ dns=.*//')|$(log 'route replace default')|$(tr '\n' ' ' < "$D/resolv.conf" | sed 's/ $//')"
printf 'STA_METRIC=4000\nSTA_DEFAULT_ROUTE=0\n' > "$T/confd"; dhcp BOUND
check "BOUND, STA_DEFAULT_ROUTE=0: no default route of the box" "" "$(log 'route replace default via .* metric')"
: > "$T/confd"
dhcp NOCARRIER
check "NOCARRIER: lease gone, the default route deleted" "0 no ip route del default dev bcawl0 metric 3000" \
	"$rc $([ -f "$S/bcawl0.lease" ] && echo yes || echo no) $(log 'route del default')"
: > "$T/run/gt-be98-wifi/stations"; dhcp BOUND
check "a dhcpcd event for a netdev that is no station: ignored" "0 no" "$rc $([ -f "$S/bcawl0.lease" ] && echo yes || echo no)"
echo bcawl0 > "$T/run/gt-be98-wifi/stations"

# ---- routed networks ----
printf 'brwifi50 192.168.50.1/24\nbrwifi60 10.60.0.1/16\n' > "$T/run/gt-be98-wifi/routed"
rm -f "$S/bcawl0.lease"; run route
check "route, no lease: addresses, rules, unreachable table" \
	"0 ip addr replace 192.168.50.1/24 dev brwifi50|ip rule add iif brwifi50 table 181 priority 181|ip addr replace 10.60.0.1/16 dev brwifi60|ip rule add iif brwifi60 table 181 priority 181|ip route replace unreachable default table 181" \
	"$rc $(log '^ip (addr replace|rule add|route replace)')"
dhcp BOUND
check "route with the lease (from the BOUND event): default via the uplink + its subnet in table 181" \
	"ip route replace default via 192.0.2.1 dev bcawl0 table 181|ip route replace 192.0.2.0/24 dev bcawl0 table 181" \
	"$(log 'table 181' | tr '|' '\n' | grep 'route replace' | tr '\n' '|' | sed 's/|$//')"
check "nft: NAT of both subnets out of the station only, forward station-only" \
	"oifname \"bcawl0\" ip saddr { 192.168.50.0/24, 10.60.0.0/16 } masquerade|iifname \"brwifi50\" oifname \"bcawl0\" accept|iifname \"brwifi50\" drop|oifname \"brwifi60\" drop" \
	"$(grep -o 'oifname "bcawl0" ip saddr {[^}]*} masquerade' "$S/gt_be98_sta.nft")|$(grep -o 'iifname "brwifi50" oifname "bcawl0" accept' "$S/gt_be98_sta.nft")|$(grep -o 'iifname "brwifi50" drop' "$S/gt_be98_sta.nft")|$(grep -o 'oifname "brwifi60" drop' "$S/gt_be98_sta.nft")"
check "nft: checked (-c) before applied" "nft -c -f $S/gt_be98_sta.nft|nft -f $S/gt_be98_sta.nft" "$(log '^nft')"
check "dnsmasq: both bridges, ranges from the second host, router/DNS = the bridge, no loopback" \
	"dhcp-option=tag:brwifi50,option:router,192.168.50.1|dhcp-range=set:brwifi50,192.168.50.2,192.168.50.254,255.255.255.0,12h|dhcp-range=set:brwifi60,10.60.0.2,10.60.255.254,255.255.0.0,12h|interface=brwifi50|except-interface=lo" \
	"$(grep -E '^(interface=brwifi50|dhcp-range|dhcp-option=tag:brwifi50,option:router|except-interface)' "$D/dnsmasq.conf" | sort -t= -k1,1 -s | grep -v '^except' | tr '\n' '|')$(grep '^except' "$D/dnsmasq.conf")"
# dnsmasq drops to nobody before it watches the resolv-file's directory
# (1102-1143-os-sta U4): that directory and file must be readable by others,
# and the station state (0700) must not hold them
rf=$(sed -n 's/^resolv-file=//p' "$D/dnsmasq.conf")
check "dnsmasq's resolv-file: outside the 0700 state, directory 0755, file 0644" "$D/resolv.conf drwxr-xr-x -rw-r--r-- drwx------" \
	"$rf $(ls -ld "${rf%/*}" | cut -c1-10) $(ls -l "$rf" | cut -c1-10) $(ls -ld "$S" | cut -c1-10)"
check "dnsmasq's pid and lease files beside it" "$D/dnsmasq.pid $D/dnsmasq.leases" \
	"$(sed -n 's/^pid-file=//p' "$D/dnsmasq.conf") $(sed -n 's/^dhcp-leasefile=//p' "$D/dnsmasq.conf")"
check "ip_forward on, the old value kept" "sysctl -q -w net.ipv4.ip_forward=1 yes" "$(log 'ip_forward') $([ -f "$S/ipfwd" ] && echo yes || echo no)"
run route
check "route again, same networks: dnsmasq not restarted" "" "$(log '^dnsmasq')"
printf 'brwifi50 192.168.50.1/24\n' > "$T/run/gt-be98-wifi/routed"; run route
check "a routed network removed: its rule and address go, dnsmasq restarted" \
	"ip rule del iif brwifi60 table 181 priority 181|ip addr del 10.60.0.1/16 dev brwifi60|yes" \
	"$(log 'brwifi60' | tr '|' '\n' | grep -E 'rule del|addr del' | head -2 | tr '\n' '|')$(log '^dnsmasq' | grep -q . && echo yes || echo no)"
printf 'brwifi50 192.168.50.1/24\nbr0 192.168.70.1/24\nbrwifi51 192.168.71.1/24\n' > "$T/run/gt-be98-wifi/routed"; run route
check "route: a non-Wi-Fi bridge refused, a missing bridge skipped, rc 1, the valid one applied" "1 no no yes" \
	"$rc $(log 'dev br0' | grep -q . && echo yes || echo no) $(log 'brwifi51' | grep -q 'addr replace' && echo yes || echo no) $(log 'addr replace 192.168.50.1/24' | grep -q . && echo yes || echo no)"
printf 'brwifi50 192.168.50.1/24\n' > "$T/run/gt-be98-wifi/routed"
# control: nft refusing the ruleset is reported
sed -i 's/^STA_TABLE=.*//' "$T/confd"; echo 'REFUSE' > "$T/run/gt-be98-wifi/refuse"
cp "$H" "$T/helper"; sed -i 's/echo "# generated by gt-be98-wifi-sta - do not edit"$/echo "# generated by gt-be98-wifi-sta - do not edit REFUSE"/' "$T/helper"
: > "$T/log"; ${SH:-sh} "$T/helper" route > "$T/out" 2>&1; rc=$?
check "control: nft -c refusing the ruleset makes route fail, nothing applied" "1 " "$rc $(log '^nft -f')"
# unroute
run unroute
check "unroute: dnsmasq stopped, nft table, rule, address, table, ip_forward restored" \
	"0 yes|nft delete table ip gt_be98_sta|ip rule del iif brwifi50 table 181 priority 181|ip addr del 192.168.50.1/24 dev brwifi50|ip route flush table 181|yes" \
	"$rc $(log 'sta-dns/dnsmasq.pid' | grep -q stop && echo yes || echo no)|$(log '^nft delete')|$(log 'rule del')|$(log 'addr del')|$(log 'route flush')|$(log 'ip_forward' | grep -q . && echo yes || echo no)"
: > "$T/run/gt-be98-wifi/routed"; run route
check "route with no routed network: unroute (no address, no nft table)" "0 " "$rc $(log 'addr replace')"

# ---- down ----
run down bcawl0
check "down: DHCP client and wpa_supplicant stopped, default route and addresses flushed" \
	"0 yes yes|ip route del default dev bcawl0 metric 3000|ip -4 addr flush dev bcawl0 scope global" \
	"$rc $(log "ssd --stop --pidfile $S/bcawl0.dhcp.pid" | grep -q . && echo yes || echo no) $(log "ssd --stop --pidfile $S/bcawl0.wpa.pid" | grep -q . && echo yes || echo no)|$(log 'route del default')|$(log 'addr flush')"
check "down: its state gone" "no no" "$([ -f "$S/bcawl0.sum" ] && echo yes || echo no) $([ -f "$S/bcawl0.lease" ] && echo yes || echo no)"
run down 'bcawl0;x'
check "down 'bcawl0;x': refused" 1 "$rc"
run nonsense
check "unknown command: usage, rc 2" "2 yes" "$rc $(grep -q 'gt-be98-wifi-sta up DEV' "$T/out" && echo yes || echo no)"

# ---- repeater: 4-address mode before the join, a port of the repeated bridge ----
mkdir -p "$T/run/gt-be98-wifi/gen"; P="$T/run/gt-be98-wifi/gen/plan"
echo 'repeater bcawl0 multiap brwifi60' > "$P"
run repeater bcawl0
check "repeater: mode and bridge from the plan" "0 multiap brwifi60" "$rc $(cat "$T/out")"
rm -f "$T/4addr-bcawl0" "$T/net/bcawl0/master"; echo 'STA_WAIT=1' > "$T/confd"
run up bcawl0 "$T/sta.conf" rs1
check "up repeater: 4addr on and the bridge port BEFORE wpa_supplicant, once" \
	"0 iw dev bcawl0 set type managed|iw dev bcawl0 set 4addr on|ip link set dev bcawl0 master brwifi60|ip link set dev bcawl0 up|wpa_supplicant" \
	"$rc $(log '^(iw dev bcawl0 set|ip link set dev bcawl0|wpa_supplicant)' | sed 's/|wpa_supplicant [^|]*/|wpa_supplicant/')"
check "up repeater: wpa_supplicant also on the bridge (-b: EAPOL to a bridge port)" "yes" \
	"$(log '^wpa_supplicant' | grep -q -- '-i bcawl0 -b brwifi60 -c' && echo yes || echo no)"
check "control: the first (3-address) station started without -b" "1 0" \
	"$(grep -c '^wpa_supplicant -B -i bcawl0 -c ' "$T/log.first") $(grep -c '^wpa_supplicant .* -b ' "$T/log.first")"
check "up repeater: no DHCP client (a bridge port is no IP host)" "no" \
	"$(log 'ssd --start' | grep -q 'dhcp.pid' && echo yes || echo no)"
run up bcawl0 "$T/sta.conf" rs1
check "up repeater again: already a port, nothing restarted or re-bridged" "0 |" \
	"$rc $(log '^wpa_supplicant')|$(log 'master brwifi')"
# the mode changes under a running station: it rejoins in the new mode
: > "$P"
run up bcawl0 "$T/sta.conf" rs2
check "repeater off under a running station: restarted, detached, 4addr off" "0 yes ip link set dev bcawl0 nomaster|iw dev bcawl0 set 4addr off" \
	"$rc $(log '^wpa_supplicant' | grep -q . && echo yes || echo no) $(log '(nomaster|4addr off)')"
check "control: a 3-address station gets its DHCP client again" "yes" \
	"$(log 'ssd --start' | grep -q 'dhcp.pid' && echo yes || echo no)"
echo 'repeater bcawl0 4addr brwifi60' > "$P"
run up bcawl0 "$T/sta.conf" rs3
check "repeater on under a running station: restarted in 4addr, bridged" "0 yes iw dev bcawl0 set 4addr on|ip link set dev bcawl0 master brwifi60" \
	"$rc $(log '^wpa_supplicant' | grep -q . && echo yes || echo no) $(log '(4addr on|master brwifi)')"
echo 'repeater bcawl0 4addr brwifi61' > "$P"
run up bcawl0 "$T/sta.conf" rs4
check "repeater bridge missing: reported, the old port left, rc 0" "0 ip link set dev bcawl0 nomaster yes" \
	"$rc $(log 'nomaster') $(grep -q 'repeater bridge brwifi61 missing' "$T/out" && echo yes || echo no)"
echo 'repeater bcawl0 4addr -' > "$P"
run repeater bcawl0
check "repeater with no repeated network: bridge -" "0 4addr -" "$rc $(cat "$T/out")"
echo 'repeater bcawl0 4addr brwifi60' > "$P"; run up bcawl0 "$T/sta.conf" rs5
run down bcawl0
check "down repeater: detached, 4addr off" "0 ip link set dev bcawl0 nomaster|iw dev bcawl0 set 4addr off" "$rc $(log '(nomaster|4addr)')"
: > "$P"; run repeater bcawl0
check "control: no repeater line, exit 1" "1 " "$rc $(cat "$T/out")"

if [ $fail = 0 ]; then echo "ALL OK ($n checks)"; else echo "FAILED"; fi
exit $fail

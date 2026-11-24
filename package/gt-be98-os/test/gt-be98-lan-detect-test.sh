#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# Unit test of `gt-be98-lan detect` (sbin/gt-be98-lan; no device, no root): the refusals that keep a
# detect from leaking (bare rnr1 a LAN port, an rnr1 VLAN device the switch does not carry), the driver
# protocol (start, the explicit stop, the stop on a signal), the capture parser (DHCP exact subnet, ARP
# and IPv4 /24 guesses, the jack set's own VIDs left out, untagged frames on a Runner port) and the
# result file. The driver, tcpdump and the rnr1 devices are fakes (GT_BE98_LAN_TEST_HOOKS).
#   sh test/gt-be98-lan-detect-test.sh [sbin/gt-be98-lan to test]
set -u
here=$(cd "$(dirname "$0")" && pwd)
LAN=${1:-$here/../src/sbin/gt-be98-lan}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
pass=0 fail=0
ok() { pass=$((pass + 1)); echo "ok   $*"; }
ko() { fail=$((fail + 1)); echo "FAIL $*"; }
check() { if [ "$1" = 0 ]; then ok "$2"; else ko "$2"; fi; }

mkdir -p "$T/rtl/dev0" "$T/net/rnr1" "$T/net/rnr2" "$T/bin" "$T/run"
# a capture as tcpdump -l -p -n -e -vv prints it (4.99 layout; DHCP options as 4.9 prints them for 3991)
cat > "$T/cap.txt" <<'EOF'
12:00:01.000001 02:00:00:00:00:61 > ff:ff:ff:ff:ff:ff, ethertype 802.1Q (0x8100), length 64: vlan 3999, p 0, ethertype ARP (0x0806), Ethernet (len 6), IPv4 (len 4), Request who-has 192.0.2.99 tell 192.0.2.97, length 46
12:00:02.000001 02:00:00:00:00:61 > ff:ff:ff:ff:ff:ff, ethertype 802.1Q (0x8100), length 64: vlan 3999, p 0, ethertype ARP (0x0806), Ethernet (len 6), IPv4 (len 4), Request who-has 192.0.2.99 tell 192.0.2.97, length 46
12:00:03.000001 02:00:00:00:00:61 > ff:ff:ff:ff:ff:ff, ethertype 802.1Q (0x8100), length 64: vlan 3999, p 0, ethertype ARP (0x0806), Ethernet (len 6), IPv4 (len 4), Request who-has 198.51.100.1 tell 0.0.0.0, length 46
12:00:04.000001 02:00:00:00:00:62 > ff:ff:ff:ff:ff:ff, ethertype 802.1Q (0x8100), length 346: vlan 3990, p 0, ethertype IPv4 (0x0800), (tos 0x10, ttl 128, id 0, offset 0, flags [none], proto UDP (17), length 328)
    192.0.2.161.67 > 255.255.255.255.68: [udp sum ok] BOOTP/DHCP, Reply, length 300, xid 0x1, Flags [Broadcast] (0x8000)
	  Your-IP 192.0.2.170
	  Server-IP 192.0.2.161
	  Client-Ethernet-Address 02:00:00:00:00:63
	  Vendor-rfc1048 Extensions
	    Magic Cookie 0x63825363
	    DHCP-Message (53), length 1: Offer
	    Server-ID (54), length 4: 192.0.2.161
	    Subnet-Mask (1), length 4: 255.255.255.240
	    Default-Gateway (3), length 4: 192.0.2.161
12:00:05.000001 02:00:00:00:00:62 > 02:00:00:00:00:63, ethertype 802.1Q (0x8100), length 102: vlan 3990, p 0, ethertype IPv4 (0x0800), (tos 0x0, ttl 64, id 1, offset 0, flags [DF], proto ICMP (1), length 84)
    203.0.113.5 > 192.0.2.170: ICMP echo request, id 1, seq 1, length 64
12:00:06.000001 02:00:00:00:00:64 > 02:00:00:00:00:65, ethertype 802.1Q (0x8100), length 102: vlan 3000, p 0, ethertype IPv4 (0x0800), (tos 0x0, ttl 64, id 1, offset 0, flags [DF], proto ICMP (1), length 84)
    198.51.100.7 > 198.51.100.9: ICMP echo request, id 1, seq 1, length 64
12:00:07.000001 02:00:00:00:00:66 > ff:ff:ff:ff:ff:ff, ethertype 802.1Q (0x8100), length 64: vlan 3951, p 0, ethertype ARP (0x0806), Ethernet (len 6), IPv4 (len 4), Request who-has 203.0.113.1 tell 203.0.113.2, length 46
12:00:08.000001 02:00:00:00:00:67 > ff:ff:ff:ff:ff:ff, ethertype 802.1Q (0x8100), length 346: vlan 3991, p 0, ethertype IPv4 (0x0800), (tos 0x10, ttl 128, id 0, offset 0, flags [none], proto UDP (17), length 328)
    192.0.2.33.67 > 255.255.255.255.68: [udp sum ok] BOOTP/DHCP, Reply, length 300, xid 0x2, Flags [Broadcast] (0x8000)
	  Your-IP 192.0.2.40
	    DHCP-Message Option 53, length 1: ACK
	    Subnet-Mask Option 1, length 4: 255.255.255.224
12:00:08.500001 02:00:00:00:00:6a > 02:00:00:00:00:6b, ethertype 802.1Q (0x8100), length 346: vlan 3992, p 0, ethertype IPv4 (0x0800), (tos 0x10, ttl 128, id 0, offset 0, flags [none], proto UDP (17), length 328)
    192.0.2.65.67 > 192.0.2.70.68: [udp sum ok] BOOTP/DHCP, Reply, length 300, xid 0x3, Flags [none] (0x0000)
	  Client-IP 192.0.2.70
	    DHCP-Message (53), length 1: ACK
	    Subnet-Mask (1), length 4: 255.255.255.192
	    Default-Gateway (3), length 4: 192.0.2.65,192.0.2.66
12:00:09.000001 02:00:00:00:00:68 > ff:ff:ff:ff:ff:ff, ethertype ARP (0x0806), length 60: Ethernet (len 6), IPv4 (len 4), Request who-has 192.0.2.1 tell 192.0.2.2, length 46
12:00:10.000001 02:00:00:00:00:69 > ff:ff:ff:ff:ff:ff, ethertype 802.1Q-QinQ (0x88a8), length 68: vlan 300, p 0, ethertype 802.1Q, vlan 30, p 0, ethertype ARP (0x0806), Ethernet (len 6), IPv4 (len 4), Request who-has 198.51.100.1 tell 198.51.100.44, length 46
EOF
cat > "$T/bin/tcpdump" <<EOF
#!/bin/sh
echo "\$*" > "$T/tcpdump.args"
cat "$T/cap.txt"
exec sleep 30
EOF
chmod +x "$T/bin/tcpdump"
# the fake driver: jack_detect status in a file, every write logged
cat > "$T/hooks" <<'EOF'
sys_write() {
	echo "$1 <- $2" >> "$FAKE/writes"
	case "$1" in
	*/jack_detect)
		case "$2" in
		start*) [ -n "${FAKE_REFUSE:-}" ] && return 1
			set -- $2; echo "state=listening jack=$2 secs=$3 left=$3 written=4091 write_ms=900 restore_ms=0 err=0 bad_vid=0 starts=1 stops=0 last_stop=none" > "$FAKE/det" ;;
		stop)	[ -n "${FAKE_STOPFAIL:-}" ] && { echo "state=failed jack=6 secs=30 left=0 written=4091 write_ms=900 restore_ms=1500 err=-5 bad_vid=3990 starts=1 stops=1 last_stop=stop" > "$FAKE/det"; return 1; }
			echo "state=idle jack=6 secs=30 left=0 written=4091 write_ms=900 restore_ms=1500 err=0 bad_vid=0 starts=1 stops=1 last_stop=stop" > "$FAKE/det" ;;
		esac ;;
	esac
	return 0
}
sys_read() { case "$1" in */jack_detect) cat "$FAKE/det" ;; *) cat "$1" ;; esac; }
wait_secs() { sleep "${FAKE_WAIT:-0.4}"; }
rnr1_vids() { printf '%s\n' ${FAKE_RNR1_VIDS:-}; }
EOF
FAKE=$T; export FAKE
reset() {
	rm -rf "$T/run" "$T/writes" "$T/tcpdump.args"; mkdir -p "$T/run"
	echo "state=idle jack=0 secs=0 left=0 written=0 write_ms=0 restore_ms=0 err=0 bad_vid=0 starts=0 stops=0 last_stop=none" > "$T/det"
	echo "4=off 5=3952 6=3951 7=off" > "$T/rtl/dev0/jack_profiles"; : > "$T/rtl/dev0/jack_detect"
	printf 'LAN_JACK_5="native=3952"\nLAN_JACK_6="native=3951"\n' > "$T/lan.conf"
	unset FAKE_REFUSE FAKE_STOPFAIL FAKE_RNR1_VIDS FAKE_WAIT
}
run() {
	GT_BE98_LAN_TEST_HOOKS=$T/hooks GT_BE98_RTL8372="$T/rtl/*" GT_BE98_SYS_NET=$T/net GT_BE98_LAN_RUN=$T/run \
	GT_BE98_TCPDUMP=$T/bin/tcpdump LAN_CONF_FILE=$T/lan.conf TMPDIR=$T ${TEST_SH:-sh} "$LAN" "$@" > "$T/out" 2> "$T/err"
}
# a JSON field through python (the output must be valid JSON)
jq_() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2], {"d": d}))' "$T/out" "$1" 2>&1; }

# 1. a jack: the driver protocol and the parse
reset; FAKE_RNR1_VIDS="3951 3952"; export FAKE_RNR1_VIDS
run detect 6 30; rc=$?
check $rc "jack 6 30 s: rc 0 ($(head -c 300 "$T/err"))"
[ "$(cat "$T/writes" 2> /dev/null | sed 's#.*/##' | tr '\n' '|')" = "jack_detect <- start 6 30|jack_detect <- stop|" ]
check $? "driver: start 6 30, then the explicit stop, nothing else ($(tr '\n' '|' < "$T/writes" 2>/dev/null))"
grep -q -- '-p' "$T/tcpdump.args" && grep -q 'rnr1' "$T/tcpdump.args" && grep -q 'vlan' "$T/tcpdump.args"
check $? "capture on rnr1, not promiscuous, tagged frames ($(cat "$T/tcpdump.args"))"
[ "$(jq_ 'd["state"]')" = done ]; check $? "state done (valid JSON: $(jq_ 'd["state"]'))"
[ "$(jq_ '[v["vid"] for v in d["vlans"]]')" = "[300, 3000, 3990, 3991, 3992, 3999]" ]
check $? "VIDs found, the set's 3951 left out, untagged ignored: $(jq_ '[v["vid"] for v in d["vlans"]]')"
[ "$(jq_ '[(v["subnet"], v["source"], v["guess"], v["router"]) for v in d["vlans"] if v["vid"] == 3990][0]')" = "('192.0.2.160/28', 'dhcp', False, '192.0.2.161')" ]
check $? "3990: the DHCP offer's /28 and router, exact: $(jq_ '[v for v in d["vlans"] if v["vid"] == 3990]')"
[ "$(jq_ '[(v["subnet"], v["source"], v["guess"]) for v in d["vlans"] if v["vid"] == 3991][0]')" = "('192.0.2.32/27', 'dhcp', False)" ]
check $? "3991: a DHCP ACK in the 4.9 layout, no router: the offered address's /27"
[ "$(jq_ '[(v["subnet"], v["source"], v["router"]) for v in d["vlans"] if v["vid"] == 3992][0]')" = "('192.0.2.64/26', 'dhcp', '192.0.2.65')" ]
check $? "3992: an ACK to an INFORM (no Your-IP): the router's /26, the first of two routers"
[ "$(jq_ '[(v["subnet"], v["source"], v["guess"], v["frames"]) for v in d["vlans"] if v["vid"] == 3999][0]')" = "('192.0.2.0/24', 'arp', True, 3)" ]
check $? "3999: 3 frames, ARP sender /24 guessed (0.0.0.0 ignored)"
[ "$(jq_ '[(v["subnet"], v["source"]) for v in d["vlans"] if v["vid"] == 3000][0]')" = "('198.51.100.0/24', 'ipv4')" ]
check $? "3000: an IPv4 source /24"
[ "$(jq_ '[(v["subnet"]) for v in d["vlans"] if v["vid"] == 300][0]')" = "198.51.100.0/24" ]
check $? "QinQ: counted under the outer VID 300"
[ "$(jq_ 'd["not_probed"]')" = "[3951, 3952]" ]; check $? "not_probed = the set's VIDs: $(jq_ 'd["not_probed"]')"
[ "$(jq_ '(d["switch"]["state"], d["switch"]["written"], d["switch"]["restore_ms"], d["untagged"])')" = "('idle', 4091, 1500, None)" ]
check $? "the driver's status in the result: $(jq_ 'd["switch"]')"
cmp -s "$T/out" "$T/run/detect-6.json"; check $? "the result file = stdout"
[ ! -d "$T/run/detect.lock" ]; check $? "lock released"
run detect-status 6; [ "$(jq_ 'd["state"]')" = done ]; check $? "detect-status 6 reads it back"
run detect-status 7; [ "$(jq_ 'd["state"]')" = none ]; check $? "detect-status 7: none"

# 2. refusals: nothing written to the driver, the reason in the result
refused() {	# what, then the run args
	what=$1; shift
	run "$@"; rc=$?
	if [ $rc != 0 ] && [ ! -s "$T/writes" ] && [ "$(jq_ 'd["state"]')" = refused ]; then ok "refused, nothing written: $what ($(jq_ 'd["error"]'))"
	else ko "not refused or the driver touched: $what rc=$rc writes=$(cat "$T/writes" 2>/dev/null) out=$(head -c 200 "$T/out")"; fi
}
reset; printf 'LAN_PORTS="rnr1 rnr2"\n' > "$T/lan.conf"; refused "bare rnr1 is a LAN port" detect 6 30
reset; FAKE_RNR1_VIDS="3951 3952 77"; export FAKE_RNR1_VIDS; refused "rnr1.77 exists, the switch does not carry 77" detect 6 30
reset; mkdir -p "$T/net/rnr1/master"; refused "rnr1 is a bridge port (live)" detect 6 30; rmdir "$T/net/rnr1/master"
# the box's own rnr1 VLAN device reader (ip -d -o link), the hook left out
grep -v '^rnr1_vids' "$T/hooks" > "$T/hooks2"
cat > "$T/bin/ip" <<'EOF'
#!/bin/sh
cat <<'L'
12: rnr1.3951@rnr1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue master brwifi100001 state UP mode DEFAULT group default qlen 1000\    link/ether 02:00:00:00:00:01 brd ff:ff:ff:ff:ff:ff promiscuity 1 allmulti 0 minmtu 0 maxmtu 65535 \    vlan protocol 802.1Q id 3951 <REORDER_HDR> \    bridge_slave state forwarding
13: rnr0.20@rnr0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP mode DEFAULT group default qlen 1000\    link/ether 02:00:00:00:00:02 brd ff:ff:ff:ff:ff:ff promiscuity 0 \    vlan protocol 802.1Q id 20 <REORDER_HDR>
L
[ -n "${FAKE_IP_EXTRA:-}" ] && echo "14: x77@rnr1: <BROADCAST> mtu 1500\    link/ether 02:00:00:00:00:03 \    vlan protocol 802.1Q id 77 <REORDER_HDR>"
exit 0
EOF
chmod +x "$T/bin/ip"
reset; PATH=$T/bin:$PATH GT_BE98_LAN_TEST_HOOKS=$T/hooks2 GT_BE98_RTL8372="$T/rtl/*" GT_BE98_SYS_NET=$T/net GT_BE98_LAN_RUN=$T/run \
	GT_BE98_TCPDUMP=$T/bin/tcpdump LAN_CONF_FILE=$T/lan.conf TMPDIR=$T ${TEST_SH:-sh} "$LAN" detect 6 30 > "$T/out" 2>&1
check $? "ip -d -o link: rnr1.3951 (carried) and rnr0.20 (not rnr1) accepted"
reset; FAKE_IP_EXTRA=1 PATH=$T/bin:$PATH GT_BE98_LAN_TEST_HOOKS=$T/hooks2 GT_BE98_RTL8372="$T/rtl/*" GT_BE98_SYS_NET=$T/net \
	GT_BE98_LAN_RUN=$T/run GT_BE98_TCPDUMP=$T/bin/tcpdump LAN_CONF_FILE=$T/lan.conf TMPDIR=$T ${TEST_SH:-sh} "$LAN" detect 6 30 > "$T/out" 2>&1
[ $? != 0 ] && [ ! -s "$T/writes" ] && grep -q 'VLAN device for 77' "$T/out"
check $? "ip -d -o link: a device x77 on rnr1, VID 77 not carried, refused (any name)"
pkill -f "$T/bin/tcpdump" 2> /dev/null
reset; refused "4 s" detect 6 4
reset; refused "121 s" detect 6 121
reset; refused "seconds not a number" detect 6 3x
reset; refused "the uplink port 3" detect 3 30
reset; refused "bare rnr1 as a port" detect rnr1 30
reset; refused "rnr0 absent" detect rnr0 30
reset; rm -f "$T/rtl/dev0/jack_detect"; refused "no jack_detect (switch off / an old driver)" detect 6 30
reset; mkdir -p "$T/run/detect.lock"; sleep 60 & lp=$!; echo $lp > "$T/run/detect.lock/pid"
refused "another detect is running (live lock holder)" detect 6 30; kill $lp 2> /dev/null
reset; mkdir -p "$T/run/detect.lock"; echo 999999 > "$T/run/detect.lock/pid"
run detect 6 30; check $? "a stale lock (dead holder) is taken over"

# 3. the driver refuses the start: no stop is written, state failed
reset; FAKE_REFUSE=1; export FAKE_REFUSE
run detect 6 30; rc=$?
[ $rc != 0 ] && [ "$(jq_ 'd["state"]')" = failed ] && ! grep -q 'stop' "$T/writes"
check $? "driver refused: failed, no stop written ($(jq_ 'd["error"]'))"
# 4. the restore did not read back: failed, the driver's status carried
reset; FAKE_STOPFAIL=1; export FAKE_STOPFAIL
run detect 6 30; rc=$?
[ $rc != 0 ] && [ "$(jq_ '(d["state"], d["switch"]["state"], d["switch"]["bad_vid"])')" = "('failed', 'failed', 3990)" ]
check $? "restore failure reported: $(jq_ 'd["error"]')"
# 5. a signal mid-window still stops the driver's window
reset; FAKE_WAIT=5; export FAKE_WAIT
GT_BE98_LAN_TEST_HOOKS=$T/hooks GT_BE98_RTL8372="$T/rtl/*" GT_BE98_SYS_NET=$T/net GT_BE98_LAN_RUN=$T/run \
	GT_BE98_TCPDUMP=$T/bin/tcpdump LAN_CONF_FILE=$T/lan.conf TMPDIR=$T ${TEST_SH:-sh} "$LAN" detect 6 30 > /dev/null 2>&1 &
bp=$!; sleep 1; kill -TERM $bp; wait $bp 2> /dev/null
[ "$(sed 's#.*/##' "$T/writes" | tr '\n' '|')" = "jack_detect <- start 6 30|jack_detect <- stop|" ] && [ ! -d "$T/run/detect.lock" ]
check $? "SIGTERM mid-window: stop written, lock released ($(tr '\n' '|' < "$T/writes"))"
pkill -f "$T/bin/tcpdump" 2> /dev/null
# 6. a Runner port: passive, no driver, untagged counted
reset; FAKE_RNR1_VIDS=""; export FAKE_RNR1_VIDS
run detect rnr2 10; rc=$?
[ $rc = 0 ] && [ ! -s "$T/writes" ] && [ "$(jq_ '(d["kind"], d["untagged"], d["not_probed"], 3951 in [v["vid"] for v in d["vlans"]])')" = "('runner', 1, [], True)" ]
check $? "rnr2: passive (nothing written), untagged 1, every VID reported"
grep -q 'rnr2' "$T/tcpdump.args" && ! grep -q ' vlan' "$T/tcpdump.args"; check $? "rnr2: every frame captured ($(cat "$T/tcpdump.args"))"
pkill -f "$T/bin/tcpdump" 2> /dev/null

echo "gt-be98-lan detect: $pass passed, $fail failed"
[ $fail = 0 ]

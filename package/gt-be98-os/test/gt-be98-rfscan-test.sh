#!/bin/sh
# shellcheck shell=busybox
# SPDX-License-Identifier: GPL-2.0
# Offline test of sbin/gt-be98-rfscan (no device, no root):
#   sh test/gt-be98-rfscan-test.sh
# iw, the sysfs radio, the driver's debugfs node, timeout, logger, sleep and
# the uptime clock are fakes:
#   iw dev IF info                 prints $T/iw/info.IF (absent = not an AP)
#   iw dev IF survey dump          prints $T/iw/survey.IF (logged "IF survey")
#   iw dev IF scan ap-force freq … prints $T/iw/scan.IF (logged "IF scan <freqs>");
#                                  $T/iw/busy makes it fail as the driver's -EBUSY
#   iw phy PHY channels            prints $T/iw/PHY.channels
# Each check is two-way where it can be: what must be there, and what must not.
# JSON validity is checked with python3 when the host has it (else SKIP, said).
set -u
here=$(cd "$(dirname "$0")" && pwd)
S="$here/../src/sbin/gt-be98-rfscan"
SH=${SH:-sh}
T=$(mktemp -d)
trap '[ -n "${KEEP:-}" ] || rm -rf "$T"' EXIT
fail=0 n=0
check() {
	n=$((n + 1))
	if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want [$2] got [$3]"; fail=1; fi
}
PY=0; command -v python3 > /dev/null 2>&1 && PY=1
# jq-like: jget <json file> <python expression on j>
jget() { python3 -I -c 'import json,sys; j=json.load(open(sys.argv[1])); v=eval(sys.argv[2]); print(" ".join(str(x) for x in v) if isinstance(v, tuple) else v)' "$1" "$2" 2>&1; }
jvalid() { python3 -I -c 'import json,sys; json.load(open(sys.argv[1])); print("valid")' "$1" 2>&1 | tail -n1; }

mkdir -p "$T/bin" "$T/iw" "$T/run/gt-be98-wifi/gen" "$T/sys" "$T/dbg/bca/dom0" "$T/dbg/bca/dom2" "$T/pci/0000:01:00.0" "$T/pci/0002:01:00.0"
export FAKE="$T" GT_BE98_RUN="$T/run" GT_BE98_IW="$T/bin/iw" GT_BE98_LOGGER="$T/bin/logger" GT_BE98_SLEEP=true \
	GT_BE98_UPTIME="$T/uptime" GT_BE98_SYSNET="$T/sys" GT_BE98_DEBUGFS="$T/dbg" GT_BE98_TIMEOUT="$T/bin/timeout"
cat > "$T/bin/iw" <<'X'
#!/bin/sh
case "$1 $3" in
"dev info") cat "$FAKE/iw/info.$2" 2>/dev/null; exit 0 ;;
"dev survey") echo "$2 survey" >> "$FAKE/cmds"; cat "$FAKE/iw/survey.$2"; exit 0 ;;
"dev scan") d=$2; shift 5; echo "$d scan $*" >> "$FAKE/cmds"
	[ -f "$FAKE/iw/busy" ] && { echo "command failed: Device or resource busy (-16)" >&2; exit 240; }
	cat "$FAKE/iw/scan.$d"; exit 0 ;;
"phy channels") cat "$FAKE/iw/$2.channels"; exit 0 ;;
esac
exit 1
X
printf '#!/bin/sh\nshift\nexec "$@"\n' > "$T/bin/timeout"
printf '#!/bin/sh\nshift 3\necho "$*" >> "$FAKE/log"\n' > "$T/bin/logger"
chmod +x "$T/bin/"*
echo "1000.00 0.00" > "$T/uptime"
tick() { echo "$1.00 0.00" > "$T/uptime"; }

# ---- the radios: bcawl0 = 5gl (PCI domain 0), bcawl2 = 6g (domain 2) ----
radio() {	# radio <dev> <phy> <pci>
	mkdir -p "$T/sys/$1/phy80211" "$T/sys/$1/statistics"
	echo "$2" > "$T/sys/$1/phy80211/name"; ln -s "$T/pci/$3" "$T/sys/$1/device"
	echo 0 > "$T/sys/$1/statistics/rx_bytes"; echo 0 > "$T/sys/$1/statistics/tx_bytes"
}
radio bcawl0 phy0 0000:01:00.0
radio bcawl2 phy2 0002:01:00.0
mkdir -p "$T/sys/bcawl0-1/statistics"; echo 0 > "$T/sys/bcawl0-1/statistics/rx_bytes"; echo 0 > "$T/sys/bcawl0-1/statistics/tx_bytes"
cat > "$T/run/gt-be98-wifi/gen/plan" <<'X'
radio 5gl bcawl0 /run/x/bcawl0.conf 0 bcawl0
radio 6g bcawl2 /run/x/bcawl2.conf 0 bcawl2
radio 2g bcawl3 /run/x/bcawl3.conf 0 bcawl3
bss bcawl0 bcawl0 0 1 0 02:00:00:00:53:a4
bss bcawl0 bcawl0-1 1 2 1 02:00:00:00:53:a5
bss bcawl2 bcawl2 0 1 0 02:00:00:00:53:ac
bss bcawl3 bcawl3 0 1 0 02:00:00:00:53:a0
X
printf 'Interface bcawl0\n\tifindex 7\n\ttype AP\n\tchannel 36 (5180 MHz), width: 80 MHz, center1: 5210 MHz\n' > "$T/iw/info.bcawl0"
cat > "$T/iw/phy0.channels" <<'X'
Band 2:
	* 5180 MHz [36]
	  Maximum TX power: 23.0 dBm
	  Channel widths: 20MHz HT40+ VHT80 VHT160
	* 5200 MHz [40]
	  Maximum TX power: 23.0 dBm
	* 5220 MHz [44]
	  Maximum TX power: 23.0 dBm
	* 5240 MHz [48]
	  Maximum TX power: 23.0 dBm
	* 5260 MHz [52]
	  Maximum TX power: 23.0 dBm
	  Radar detection
	  DFS state: usable (for 1000 sec)
	  DFS CAC time: 60000 ms
	* 5280 MHz [56]
	  Radar detection
	  DFS state: usable (for 1000 sec)
	  DFS CAC time: 60000 ms
	* 5300 MHz [60]
	  Radar detection
	  DFS state: usable (for 1000 sec)
	  DFS CAC time: 60000 ms
	* 5320 MHz [64]
	  Radar detection
	  DFS state: usable (for 1000 sec)
	  DFS CAC time: 60000 ms
	* 5500 MHz [100]
	  Radar detection
	  DFS state: unavailable (for 10 sec)
	  DFS CAC time: 60000 ms
	* 5745 MHz [149] (disabled)
X
sv() {	# sv <freq> <inuse> <noise> <active> <busy> <rx> <tx> : one iw survey record
	printf '\tfrequency:\t\t\t%s MHz%s\n' "$1" "$([ "$2" = 1 ] && echo ' [in use]')"
	[ "$3" != - ] && printf '\tnoise:\t\t\t\t%s dBm\n' "$3"
	[ "$4" != - ] && printf '\tchannel active time:\t\t%s ms\n\tchannel busy time:\t\t%s ms\n\tchannel receive time:\t\t%s ms\n\tchannel transmit time:\t\t%s ms\n' "$4" "$5" "$6" "$7"
	return 0
}
nd() {	# nd <freq> <noise> <time> <busy> <rx> <tx> <bss> <obss> <nonwifi> : one node `surv` line
	echo "surv freq=$1 noise=$2 time_ms=$3 busy_ms=$4 rx_ms=$5 tx_ms=$6 bss_rx_ms=$7 obss_ms=$8 nonwifi_ms=$9"
}
NODE=$T/dbg/bca/dom0/fscan
# refresh 1: our 5180 cumulative 10 s, 60 % busy (tx 15 %, our BSS 10 %, OBSS 20 %, non-Wi-Fi 10 %);
# 5200 / 5220 / 5240 have no time record yet (only noise on 5200)
{ echo "Survey data from bcawl0"; sv 5180 1 -92 10000 6000 4000 1500; sv 5200 0 -95 - - - -; sv 5220 0 - - - - -; sv 5240 0 - - - - -
  sv 5260 0 - - - - -; sv 5280 0 - - - - -; sv 5300 0 - - - - -; sv 5320 0 - - - - -; } > "$T/iw/survey.bcawl0"
{ echo "FSCAN state=RUNNING"; echo "surv channels=2"; nd 5180 -92 10000 6000 4000 1500 1000 2000 1000; } > "$NODE"

O=$T/o.json
# ---- T1 show before any refresh: channels from the phy, nothing measured, no recommendation ----
$SH "$S" show 5gl > "$O"; rc=$?
check "T1 show: exit 0" 0 "$rc"
check "T1 show: no radio I/O (no survey, no scan)" "" "$(cat "$T/cmds" 2>/dev/null)"
if [ $PY = 1 ]; then
	check "T1 JSON valid" valid "$(jvalid "$O")"
	check "T1 serving, ours 5180/80 centre 5210" "True 5180 80 5210" "$(jget "$O" "j['serving'], j['ours']['freq'], j['ours']['width'], j['ours']['center_freq']")"
	check "T1 10 channels (disabled 149 listed as disabled), none measured" "10 1 0" \
		"$(jget "$O" "len(j['channels']), sum(c['disabled'] for c in j['channels']), sum(c['measured'] for c in j['channels'])")"
	check "T1 in_use = the 4 pieces of our 80 MHz block" "[36, 40, 44, 48]" "$(jget "$O" "[c['ch'] for c in j['channels'] if c['in_use']]")"
	check "T1 radar channels flagged, 100 in NOP (unavailable)" "[52, 56, 60, 64, 100] unavailable" \
		"$(jget "$O" "[c['ch'] for c in j['channels'] if c['dfs']], [c for c in j['channels'] if c['ch'] == 100][0]['dfs_state']")"
	check "T1 recommendation none (our channel unmeasured)" "none" "$(jget "$O" "j['recommendation']['action']")"
else
	echo "SKIP T1 JSON checks: no python3 on this host"
fi

# ---- T2 survey refresh 1: cumulative basis, the split from the node ----
: > "$T/cmds"
$SH "$S" survey 5gl > "$O"
check "T2 survey: one survey dump, no scan" "bcawl0 survey" "$(cat "$T/cmds")"
if [ $PY = 1 ]; then
	check "T2 JSON valid" valid "$(jvalid "$O")"
	check "T2 5180: cumulative, busy 60 ours 25 (tx 15 + bss 10) other Wi-Fi 20 non-Wi-Fi 10, noise -92" \
		"cumulative 60.0 25.0 20.0 10.0 -92 10000" \
		"$(jget "$O" "' '.join(str(x) for x in [(c['basis'], c['busy_pct'], c['ours_pct'], c['other_wifi_pct'], c['nonwifi_pct'], c['noise_dbm'], c['sample_ms']) for c in j['channels'] if c['ch'] == 36][0])")"
	check "T2 5200: noise read, NOT measured (no time record is not 0 %)" "False None -95" \
		"$(jget "$O" "[(c['measured'], c['busy_pct'], c['noise_dbm']) for c in j['channels'] if c['ch'] == 40][0]")"
	check "T2 split true" True "$(jget "$O" "j['split']")"
fi

# ---- T3 survey refresh 2, 30 s later: a DELTA window ----
tick 1030
{ echo "Survey data from bcawl0"; sv 5180 1 -91 40000 15000 9000 4500; sv 5200 0 -95 - - - -; sv 5220 0 - - - - -; sv 5240 0 - - - - -
  sv 5260 0 - - - - -; sv 5280 0 - - - - -; sv 5300 0 - - - - -; sv 5320 0 - - - - -; } > "$T/iw/survey.bcawl0"
{ echo "surv channels=1"; nd 5180 -91 40000 15000 9000 4500 4000 3500 1500; } > "$NODE"
$SH "$S" survey 5gl > "$O"
if [ $PY = 1 ]; then
	# delta 30000 ms: busy 9000 (30 %), tx 3000 + bss 3000 = 20 %, obss 1500 = 5 %, nonwifi 500 = 1.7 %
	check "T3 5180: delta basis over 30 s: busy 30 ours 20 other 5 non-Wi-Fi 1.7, age 0" "delta 30000 30.0 20.0 5.0 1.7 0" \
		"$(jget "$O" "' '.join(str(x) for x in [(c['basis'], c['sample_ms'], c['busy_pct'], c['ours_pct'], c['other_wifi_pct'], c['nonwifi_pct'], c['age_s']) for c in j['channels'] if c['ch'] == 36][0])")"
fi
# T3b the same counters again: nothing new, the previous window is kept (age grows), not zeroed
tick 1040
$SH "$S" survey 5gl > "$O"
if [ $PY = 1 ]; then
	check "T3b unchanged counters keep the last window (busy 30, age 10 s)" "delta 30.0 10" \
		"$(jget "$O" "' '.join(str(x) for x in [(c['basis'], c['busy_pct'], c['age_s']) for c in j['channels'] if c['ch'] == 36][0])")"
fi
# T3c a firmware reset (time went back): cumulative again, never negative
tick 1050
{ echo "Survey data from bcawl0"; sv 5180 1 -91 2000 500 300 100; } > "$T/iw/survey.bcawl0"
{ echo "surv channels=1"; nd 5180 -91 2000 500 300 100 100 100 100; } > "$NODE"
$SH "$S" survey 5gl > "$O"
if [ $PY = 1 ]; then
	check "T3c counters went backwards: cumulative 25 %, not a negative delta" "cumulative 25.0" \
		"$(jget "$O" "' '.join(str(x) for x in [(c['basis'], c['busy_pct']) for c in j['channels'] if c['ch'] == 36][0])")"
fi

# ---- T4 the node absent (an older driver): busy from iw, the split null ----
mv "$NODE" "$NODE.off"
tick 1080
{ echo "Survey data from bcawl0"; sv 5180 1 -91 32000 8000 5000 2000; } > "$T/iw/survey.bcawl0"
$SH "$S" survey 5gl > "$O"
if [ $PY = 1 ]; then
	check "T4 no node: busy 25 % from iw, ours / other / non-Wi-Fi null, split false" "25.0 None None None False" \
		"$(jget "$O" "' '.join(str(x) for x in [(c['busy_pct'], c['ours_pct'], c['other_wifi_pct'], c['nonwifi_pct']) for c in j['channels'] if c['ch'] == 36][0] + (j['split'],))")"
fi
mv "$NODE.off" "$NODE"

# ---- T5 scan now: the scan list, the neighbours, our own BSSIDs left out ----
cat > "$T/iw/scan.bcawl0" <<'X'
BSS 02:00:00:00:53:a5(on bcawl0)
	freq: 5180.0
	signal: -30.00 dBm
	last seen: 0 ms ago
	SSID: ours-second
BSS 02:00:00:00:53:a0(on bcawl0)
	freq: 5180.0
	signal: -30.00 dBm
	last seen: 0 ms ago
	SSID: ours-other-radio
BSS 0a:11:22:33:44:01(on bcawl0)
	TSF: 1 usec (0d, 00:00:00)
	freq: 5180.0
	beacon interval: 100 TUs
	signal: -50.00 dBm
	last seen: 2000 ms ago
	SSID: Neigh\x20One\xc3\xa9
	HT operation:
		 * primary channel: 36
		 * secondary channel offset: above
		 * STA channel width: any
	VHT operation:
		 * channel width: 1 (80 MHz)
		 * center freq segment 1: 42
		 * center freq segment 2: 0
		 * VHT basic MCS set: 0xfffc
BSS 0a:11:22:33:44:02(on bcawl0)
	freq: 5200
	signal: -70.00 dBm
	last seen: 100 ms ago
	SSID:
	HT operation:
		 * primary channel: 40
		 * secondary channel offset: below
BSS 0a:11:22:33:44:03(on bcawl0)
	freq: 5280
	signal: -60.00 dBm
	last seen: 100 ms ago
	SSID: far\x5cx
	HT operation:
		 * primary channel: 56
		 * secondary channel offset: no secondary
BSS 0a:11:22:33:44:04(on bcawl0)
	freq: 5260
	signal: -80.00 dBm
	last seen: 100 ms ago
	SSID: wide
	HE Operation:
		HE Operation Parameters: (0x0000)
	EHT Operation:
		EHT Operation Info: 0x
			Channel Width: 160 MHz
			Center Frequency Segment 0: 58
			Center Frequency Segment 1: 50
X
# the train lit 5200-5320 too: the survey after it has their records (5260-5320 quiet, 5200-5240 busy)
tick 1100
{ echo "Survey data from bcawl0"; sv 5180 1 -91 62000 23000 14000 5000; sv 5200 0 -95 40 30 30 0; sv 5220 0 -94 40 32 30 0; sv 5240 0 -94 40 28 25 0
  sv 5260 0 -96 110 5 5 0; sv 5280 0 -96 110 8 8 0; sv 5300 0 -96 110 3 3 0; sv 5320 0 -96 110 4 4 0; } > "$T/iw/survey.bcawl0"
{ echo "surv channels=8"; nd 5180 -91 62000 23000 14000 5000 3000 9000 2000; nd 5200 -95 40 30 30 0 0 25 5; nd 5220 -94 40 32 30 0 0 25 5
  nd 5240 -94 40 28 25 0 0 20 5; nd 5260 -96 110 5 5 0 0 3 2; nd 5280 -96 110 8 8 0 0 5 3; nd 5300 -96 110 3 3 0 0 1 2; nd 5320 -96 110 4 4 0 0 2 2; } > "$NODE"
: > "$T/cmds"
$SH "$S" scan 5gl > "$O"
check "T5 scan: ONE train over the enabled, not-in-NOP channels (149 disabled and 100 unavailable left out), then a survey" \
	"bcawl0 scan 5180 5200 5220 5240 5260 5280 5300 5320|bcawl0 survey" "$(tr '\n' '|' < "$T/cmds" | sed 's/|$//')"
if [ $PY = 1 ]; then
	check "T5 JSON valid" valid "$(jvalid "$O")"
	check "T5 4 neighbours, our 3 BSSIDs (this radio's two, another radio's one) left out" \
		"['0a:11:22:33:44:01', '0a:11:22:33:44:03', '0a:11:22:33:44:02', '0a:11:22:33:44:04']" "$(jget "$O" "[x['bssid'] for x in j['neighbours']]")"
	check "T5 VHT80 neighbour: 80 MHz centre 5210, co-channel, -50 dBm, seen 2 s ago, SSID bytes exact (space + UTF-8)" \
		"80 5210 co-channel -50 2 4e65696768204f6e65c3a9 Neigh One?? False" \
		"$(jget "$O" "' '.join(str(x) for x in [(n['width'], n['center_freq'], n['overlap'], n['signal_dbm'], n['last_seen_s'], n['ssid_hex'], n['ssid'], n['hidden']) for n in j['neighbours'] if n['bssid'].endswith('01')][0])")"
	check "T5 HT40-below hidden neighbour on 5200: 40 MHz centre 5190, overlapping, ssid null" "40 5190 overlapping None True" \
		"$(jget "$O" "' '.join(str(x) for x in [(n['width'], n['center_freq'], n['overlap'], n['ssid'], n['hidden']) for n in j['neighbours'] if n['bssid'].endswith('02')][0])")"
	check "T5 20 MHz neighbour on 5280: no overlap; backslash escaped as \\x5c in the hex" "20 5280 none 6661725c78" \
		"$(jget "$O" "' '.join(str(x) for x in [(n['width'], n['center_freq'], n['overlap'], n['ssid_hex']) for n in j['neighbours'] if n['bssid'].endswith('03')][0])")"
	check "T5 EHT 160 MHz neighbour: width from the EHT element (segment 1 = 5250), overlapping" "160 5250 overlapping" \
		"$(jget "$O" "' '.join(str(x) for x in [(n['width'], n['center_freq'], n['overlap']) for n in j['neighbours'] if n['bssid'].endswith('04')][0])")"
	check "T5 per-channel neighbour counts (36: 1, 40: 1, 52: 1, 56: 1)" "1 1 1 1 0" \
		"$(jget "$O" "' '.join(str([c['neighbours'] for c in j['channels'] if c['ch'] == k][0]) for k in (36, 40, 52, 56, 44))")"
	check "T5 scan state idle, full scan age 0" "idle 0" "$(jget "$O" "j['scan_state'], j['full_scan_age_s']")"
	# T6 the recommendation: 36-48 busy (5200-5240 ~70 % of their dwell, a co-channel -50 dBm
	# neighbour), 52-64 quiet: MOVE to 52/80, a radar block (CAC 60 s)
	check "T6 recommendation MOVE to ch 52 / 80 MHz centre 5290, radar, cac 60 s" "move 52 5260 80 5290 True 60" \
		"$(jget "$O" "' '.join(str(j['recommendation'][k]) for k in ('action', 'ch', 'freq', 'width', 'center_freq', 'dfs', 'cac_s'))")"
	check "T6 candidates: exactly the two complete 80 MHz blocks (100 is in NOP, 149 disabled)" "[36, 52]" "$(jget "$O" "[c['ch'] for c in j['candidates']]")"
	check "T6 our own block's busy leaves out our own tx + bss_rx; its score beats nobody" "True" \
		"$(jget "$O" "[c for c in j['candidates'] if c['ours']][0]['score'] > [c for c in j['candidates'] if not c['ours']][0]['score']")"
	check "T6 chan_switch arguments for hostapd" "5 5260 center_freq1=5290 bandwidth=80" "$(jget "$O" "j['recommendation']['chan_switch']")"
fi

# ---- T7 a scan the driver refuses (-EBUSY: a CAC, a CSA): state named, the cache kept ----
touch "$T/iw/busy"
tick 1110
$SH "$S" scan 5gl > "$O"; rc=$?
check "T7 refused scan: exit 0" 0 "$rc"
if [ $PY = 1 ]; then
	check "T7 scan_state names the refusal, the 4 neighbours are still there" "True 4" \
		"$(jget "$O" "j['scan_state'].startswith('refused:') and 'busy' in j['scan_state'], len(j['neighbours'])")"
fi
rm -f "$T/iw/busy"

# ---- T8 a held lock (another scan or the daemon's step): no second scan is sent ----
mkdir -p "$T/run/gt-be98-rfscan/5gl/lock"; sleep 300 & SPID=$!; echo $SPID > "$T/run/gt-be98-rfscan/5gl/lock/pid"
: > "$T/cmds"
$SH "$S" scan 5gl > "$O"
check "T8 lock held by a live process: no scan, no survey" "" "$(cat "$T/cmds")"
[ $PY = 1 ] && check "T8 scan_state busy" busy "$(jget "$O" "j['scan_state']")"
kill $SPID 2>/dev/null; wait $SPID 2>/dev/null
: > "$T/cmds"
$SH "$S" scan 5gl > /dev/null
check "T8b a stale lock (its process gone) is taken over" "bcawl0 scan 5180 5200 5220 5240 5260 5280 5300 5320|bcawl0 survey" "$(tr '\n' '|' < "$T/cmds" | sed 's/|$//')"

# ---- T9 the quiet case: ours is the best, STAY ----
tick 1200
# the 30 s window: busy 13200 ms of 30000 (44 %), of which our tx 6000 + our BSS 5000 = 37 %: others
# 2200 ms (7.3 %) -> score 0.5 x 0.073 + 0.2 x 0.167 = 0.070; the 52-64 block scores 0.063 (5280's
# 8 of 110 ms, noise -96): 10 % better, under the 20 % margin -> STAY. OBSS went BACK (9000 -> 1000):
# a torn part, published as null, never negative.
{ echo "Survey data from bcawl0"; sv 5180 1 -95 92000 36200 20000 11000; } > "$T/iw/survey.bcawl0"
{ echo "surv channels=1"; nd 5180 -95 92000 36200 20000 11000 8000 1000 2500; } > "$NODE"
printf 'BSS 0a:11:22:33:44:09(on bcawl0)\n\tfreq: 5745\n\tsignal: -88.00 dBm\n\tlast seen: 0 ms ago\n\tSSID: x\n' > "$T/iw/scan.bcawl0"
mv "$T/run/gt-be98-rfscan/5gl/nbr" "$T/nbr.keep"
$SH "$S" scan 5gl > "$O"
if [ $PY = 1 ]; then
	check "T9 44 % busy but 37 % of it ours: STAY (a 10 % better block is under the 20 % margin)" "stay 0.07 0.063" \
		"$(jget "$O" "j['recommendation']['action'], j['recommendation']['score_ours'], j['recommendation']['score_best']")"
	check "T9 a part that went backwards (OBSS) is null, never negative; busy 44 ours 36.7" "None 44.0 36.7" \
		"$(jget "$O" "[(c['other_wifi_pct'], c['busy_pct'], c['ours_pct']) for c in j['channels'] if c['ch'] == 36][0]")"
fi
mv "$T/nbr.keep" "$T/run/gt-be98-rfscan/5gl/nbr"

# ---- T10 neighbour ageing: a record not seen for > NBR_TTL (3600 s) is dropped at the next merge ----
tick 6000
printf 'BSS 0a:11:22:33:44:0a(on bcawl0)\n\tfreq: 5220\n\tsignal: -75.00 dBm\n\tlast seen: 0 ms ago\n\tSSID: fresh\n' > "$T/iw/scan.bcawl0"
$SH "$S" scan 5gl > "$O"
[ $PY = 1 ] && check "T10 after 1 h only the fresh record is left" "['0a:11:22:33:44:0a']" "$(jget "$O" "[n['bssid'] for n in j['neighbours']]")"

# ---- T11 6 GHz: the scan list is the PSCs + our own channel ----
printf 'Interface bcawl2\n\ttype AP\n\tchannel 33 (6115 MHz), width: 160 MHz, center1: 6185 MHz\n' > "$T/iw/info.bcawl2"
{ echo "Band 4:"; for c in 1 5 9 13 17 21 25 29 33 37 41 45 49 53 57 61 65 69 73 77 81 85 89 93; do printf '\t* %d MHz [%d] \n\t  No IR\n' $((5950 + 5 * c)) $c; done
  printf '\t* 6435 MHz [97] (disabled)\n'; } > "$T/iw/phy2.channels"
{ echo "Survey data from bcawl2"; sv 6115 1 -95 1000 100 50 20; } > "$T/iw/survey.bcawl2"
printf 'BSS 0a:11:22:33:44:66(on bcawl2)\n\tfreq: 6135\n\tsignal: -61.00 dBm\n\tlast seen: 0 ms ago\n\tSSID: six\n\tHE Operation:\n\t\t6 GHz Operation Information: 0x\n\t\t\tPrimary Channel: 37\n\t\t\tChannel Width: 80+80 or 160 MHz\n\t\t\tCenter Frequency Segment 0: 39\n\t\t\tCenter Frequency Segment 1: 47\n' > "$T/iw/scan.bcawl2"
: > "$T/cmds"
$SH "$S" scan 6g > "$O"
check "T11 6 GHz train: PSCs 5 21 37 53 69 85 + our 33, nothing else" "bcawl2 scan 5975 6055 6115 6135 6215 6295 6375|bcawl2 survey" "$(tr '\n' '|' < "$T/cmds" | sed 's/|$//')"
if [ $PY = 1 ]; then
	check "T11 JSON valid; 6 GHz HE neighbour 160 MHz centre 6185 (segment 1), co-located block = overlapping" "valid 160 6185 overlapping" \
		"$(jvalid "$O") $(jget "$O" "' '.join(str(x) for x in [(n['width'], n['center_freq'], n['overlap']) for n in j['neighbours']][0])")"
	check "T11 6 GHz split absent (no dom2 node): split false, the node of dom0 is not read for dom2" "False" "$(jget "$O" "j['split']")"
fi

# ---- T12 the daemon: one tick = a survey and ONE single-channel step per serving radio ----
rm -f "$T/iw/info.bcawl2"	# 6g not serving: skipped
: > "$T/cmds"
GT_BE98_TICKS=1 $SH "$S" run > /dev/null 2>&1
check "T12 tick 1: 5gl one step (the next round-robin channel), then ONE survey; 6g (not serving) untouched" \
	"bcawl0 scan 5180|bcawl0 survey" "$(tr '\n' '|' < "$T/cmds" | sed 's/|$//')"
: > "$T/cmds"; tick 6030
GT_BE98_TICKS=1 $SH "$S" run > /dev/null 2>&1
check "T12b tick 2: the NEXT channel" "bcawl0 scan 5200|bcawl0 survey" "$(tr '\n' '|' < "$T/cmds" | sed 's/|$//')"
# T13 the traffic gate: 30 s at 80 Mbit/s on the second BSS -> the step is skipped
echo 300000000 > "$T/sys/bcawl0-1/statistics/tx_bytes"
: > "$T/cmds"; tick 6060
GT_BE98_TICKS=1 $SH "$S" run > /dev/null 2>&1
check "T13 traffic above 10 Mbit/s: survey only, the step skipped" "bcawl0 survey" "$(tr '\n' '|' < "$T/cmds" | sed 's/|$//')"
# T13b ... at most BG_MAX_SKIP (10) ticks in a row, then one step goes anyway
i=0; b=300000000; t=6060
while [ $i -lt 9 ]; do i=$((i + 1)); b=$((b + 300000000)); t=$((t + 30)); echo $b > "$T/sys/bcawl0-1/statistics/tx_bytes"; tick $t; GT_BE98_TICKS=1 $SH "$S" run > /dev/null 2>&1; done
check "T13b 10 skips so far (no step since T12b)" "0" "$(grep -c 'scan 5220' "$T/cmds")"
b=$((b + 300000000)); t=$((t + 30)); echo $b > "$T/sys/bcawl0-1/statistics/tx_bytes"; tick $t
: > "$T/cmds"; GT_BE98_TICKS=1 $SH "$S" run > /dev/null 2>&1
check "T13c the 11th busy tick steps anyway (a busy radio is refreshed every ~5 min)" "bcawl0 scan 5220|bcawl0 survey" "$(tr '\n' '|' < "$T/cmds" | sed 's/|$//')"

# ---- T14 2.4 GHz: candidates 1 / 6 / 11 / 13, a neighbour 2 channels away overlaps in part ----
radio bcawl3 phy3 0003:01:00.0 2>/dev/null; mkdir -p "$T/pci/0003:01:00.0"
printf 'Interface bcawl3\n\ttype AP\n\tchannel 1 (2412 MHz), width: 20 MHz, center1: 2412 MHz\n' > "$T/iw/info.bcawl3"
{ echo "Band 1:"; for c in 1 2 3 4 5 6 7 8 9 10 11 12 13; do printf '\t* %d MHz [%d] \n' $((2407 + 5 * c)) $c; done; printf '\t* 2484 MHz [14] (disabled)\n'; } > "$T/iw/phy3.channels"
{ echo "Survey data from bcawl3"; sv 2412 1 -90 30000 18000 15000 1000; sv 2437 0 -93 40 6 5 0; sv 2462 0 -93 40 20 18 0; sv 2472 0 -93 40 30 25 0; } > "$T/iw/survey.bcawl3"
printf 'BSS 0a:11:22:33:44:24(on bcawl3)\n\tfreq: 2422\n\tsignal: -45.00 dBm\n\tlast seen: 0 ms ago\n\tSSID: three\n' > "$T/iw/scan.bcawl3"
: > "$T/cmds"
$SH "$S" scan 2g > "$O"
check "T14 2.4 GHz train: the 13 enabled channels (14 disabled)" "13" "$(sed -n 's/^bcawl3 scan //p' "$T/cmds" | wc -w | tr -d ' ')"
if [ $PY = 1 ]; then
	check "T14 candidates 1 6 11 13; ch 3 neighbour overlaps ours" "[1, 6, 11, 13] overlapping" \
		"$(jget "$O" "[c['ch'] for c in j['candidates']], j['neighbours'][0]['overlap']")"
	check "T14 recommendation: move to 6 (the quietest measured, far from the ch 3 neighbour)" "move 6" \
		"$(jget "$O" "j['recommendation']['action'], j['recommendation']['ch']")"
	check "T14 the ch 3 neighbour weighs most on ch 1, less on 6 (15 MHz away: the masks overlap in part), not on 11" "True True 0.0" \
		"$(jget "$O" "(lambda k: (k[1] > k[6] > 0, k[1] > 0.5, k[11]))({c['ch']: c['nbr'] for c in j['candidates']})")"
fi

# ---- T15 usage ----
$SH "$S" scan 7g > "$O"; rc=$?
check "T15 a bad band: exit 2, a JSON error, no I/O" "2 error" "$rc $(sed -n 's/^{"\(error\)".*/\1/p' "$O")"
$SH "$S" show 6g > "$O"
[ $PY = 1 ] && check "T15b show of a radio that is not serving: serving false, recommendation none" "False none" "$(jget "$O" "j['serving'], j['recommendation']['action']")"

echo "$n checks"
if [ $fail = 0 ]; then echo PASS; else echo FAIL; fi
exit $fail

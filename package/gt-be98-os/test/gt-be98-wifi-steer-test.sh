#!/bin/sh
# shellcheck shell=busybox
# SPDX-License-Identifier: GPL-2.0
# Offline test of sbin/gt-be98-wifi-steer (no device, no root):
#   sh test/gt-be98-wifi-steer-test.sh
# The plan is the real generator's (KV=1); hostapd_cli, iw, logger, sleep
# and the uptime clock are fakes:
#   hostapd_cli -p DIR -i IF raw CMD ...  per BSS: SHOW_NEIGHBOR prints its
#       own entry ($T/hap/IF.own) then the entries set on it ($T/hap/IF.db);
#       SET_NEIGHBOR / REMOVE_NEIGHBOR edit IF.db; STA <mac> prints
#       ext_capab=$T/hap/sta.<mac>; BSS_TM_REQ answers OK. Every command is
#       logged to $T/cmds as "IF CMD ...". A BSS with $T/hap/IF.down does
#       not answer (not running)
#   iw dev IF station dump               prints $T/iw/IF
# Each check is two-way: what must happen, and what must not.
set -u
here=$(cd "$(dirname "$0")" && pwd)
S="$here/../src/sbin/gt-be98-wifi-steer"
G="$here/../src/sbin/gt-be98-wifi-gen"
SH=${SH:-sh}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0 n=0
check() {
	n=$((n + 1))
	if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want [$2] got [$3]"; fail=1; fi
}
mkdir -p "$T/bin" "$T/hap" "$T/iw" "$T/run/gt-be98-wifi/gen" "$T/confd"
export FAKE="$T" GT_BE98_RUN="$T/run" GT_BE98_CONFD="$T/confd" GT_BE98_UPTIME="$T/uptime" \
	GT_BE98_HOSTAPD_CLI="$T/bin/hostapd_cli" GT_BE98_IW="$T/bin/iw" GT_BE98_LOGGER="$T/bin/logger" \
	GT_BE98_SLEEP=true
cat > "$T/bin/hostapd_cli" <<'X'
#!/bin/sh
ifn=
while [ $# -gt 0 ]; do case $1 in -i) ifn=$2; shift 2 ;; -p) shift 2 ;; raw) shift; break ;; *) break ;; esac; done
[ -f "$FAKE/hap/$ifn.down" ] && { echo "Failed to connect to hostapd - wpa_ctrl_open: No such file or directory"; exit 255; }
echo "$ifn $*" >> "$FAKE/cmds"
db=$FAKE/hap/$ifn.db
touch "$db"
case "$1" in
SHOW_NEIGHBOR) cat "$FAKE/hap/$ifn.own" "$db" ;;
SET_NEIGHBOR) grep -v "^$2 " "$db" > "$db.n"; shift; echo "$*" >> "$db.n"; mv "$db.n" "$db"; echo OK ;;
REMOVE_NEIGHBOR) if grep -q "^$2 " "$db"; then grep -v "^$2 " "$db" > "$db.n"; mv "$db.n" "$db"; echo OK; else echo FAIL; fi ;;
STA) if [ -f "$FAKE/hap/sta.$2" ]; then echo "$2"; echo "flags=[AUTH][ASSOC][AUTHORIZED]"; echo "ext_capab=$(cat "$FAKE/hap/sta.$2")"; else echo FAIL; fi ;;
BSS_TM_REQ) echo OK ;;
*) echo "UNKNOWN COMMAND" ;;
esac
X
printf '#!/bin/sh\n[ "$1 $3 $4" = "dev station dump" ] && cat "$FAKE/iw/$2" 2>/dev/null\nexit 0\n' > "$T/bin/iw"
# logger -t TAG -- MSG
printf '#!/bin/sh\nshift 3\necho "$*" >> "$FAKE/log"\n' > "$T/bin/logger"
chmod +x "$T/bin/"*

# ---- the plan: network 1 kv steer on 2g 5gl 6g, network 2 kv (no steer)
# on 2g 5gl, network 3 no kv on 2g ----
M="2g=00:00:5e:00:53:a0 5gl=00:00:5e:00:53:a4 5gh=00:00:5e:00:53:a8 6g=00:00:5e:00:53:ac"
net() { printf 'network=%s\nssid=%s\nsecurity=sae\npassphrase=%s\nbands=%s\nvlan=%s\n' "$@"; }
mkplan() {	# mkplan BANDS_OF_NETWORK_1
	{ net 1 one password1 "$1" 1; printf 'kv=1\nsteer=1\n'; net 2 two password2 "2g 5gl" 2; printf 'kv=1\n'
	  net 3 three password3 2g 3; } > "$T/nets"
	GT_BE98_KV=1 $SH "$G" -n "$T/nets" -o "$T/run/gt-be98-wifi/gen" -s "$T/slots" -m "$M" 2> "$T/generr"
}
mkplan "2g 5gl 6g"; check "the generator's plan: kv 1 1 and kv 2 0" "0 kv 1 1|kv 2 0" \
	"$? $(grep '^kv ' "$T/run/gt-be98-wifi/gen/plan" | tr '\n' '|' | sed 's/|$//')"
P=$T/run/gt-be98-wifi/gen/plan
bss() { awk -v n="$1" -v d="$2" '$1 == "bss" && $5 == n && $2 == d { print $3 }' "$P"; }	# ifname of net $1 on radio $2
bid() { awk -v i="$1" '$1 == "bss" && $3 == i { print $7 }' "$P"; }
A2=$(bss 1 bcawl3) A5=$(bss 1 bcawl0) A6=$(bss 1 bcawl2) B2=$(bss 2 bcawl3) B5=$(bss 2 bcawl0) C2=$(bss 3 bcawl3)
check "the BSSes: net 1 on 3 radios, net 2 on 2, net 3 on 1" "bcawl3 bcawl0 bcawl2 bcawl3-1 bcawl0-1 bcawl3-2" "$A2 $A5 $A6 $B2 $B5 $C2"
# each BSS's own entry, as hostapd prints it (bssid_info 0x0000008f;
# 2g op 81 ch 1 phy 7, 5gl op 128 ch 36 phy 9 + a wide-bandwidth subelement,
# 6g op 131 ch 37 phy 14)
hx() { echo "$1" | tr -d ':'; }
ssidhex() { printf '%s' "$1" | od -An -tx1 | tr -d ' \n'; }
own() {	# own IF SSID OPCHPHY [SUB]
	echo "$(bid "$1") ssid=$(ssidhex "$2") nr=$(hx "$(bid "$1")")8f000000$3${4:-}" > "$T/hap/$1.own"
}
own "$A2" one 510107; own "$A5" one 802409 0603002a00; own "$A6" one 83250e
own "$B2" two 510107; own "$B5" two 802409; own "$C2" three 510107
I6=$(bid "$A6")	# kept: the 6g BSS leaves the plan in 3.

tick() { t=$(( $(cat "$T/uptime" 2>/dev/null | cut -d. -f1) + 5 )); echo "$t.00 1.00" > "$T/uptime"; : > "$T/cmds"; $SH "$S" once; }
echo "100.00 1.00" > "$T/uptime"
db() { cut -d' ' -f1 "$T/hap/$1.db" 2>/dev/null | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//'; }
srt() { for x in "$@"; do echo "$x"; done | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//'; }

# ---- 1. neighbour sync ----
tick
check "sync: 8 SET_NEIGHBOR (net 1: 3 x 2 siblings, net 2: 2 x 1), all OK, none on net 3" "8 8 0" \
	"$(grep -c ' SET_NEIGHBOR ' "$T/cmds") $(grep -c '^NBR set .* rc=OK$' "$T/log") $(grep -c "^$C2 SET_NEIGHBOR" "$T/cmds")"
check "sync: $A2 holds exactly its siblings $A5 $A6" "$(srt "$(bid "$A5")" "$(bid "$A6")")" "$(db "$A2")"
check "sync: $A6 holds exactly $A2 $A5" "$(srt "$(bid "$A2")" "$(bid "$A5")")" "$(db "$A6")"
check "sync: $B2 holds exactly $B5 (never network 1's)" "$(bid "$B5")" "$(db "$B2")"
check "sync: $C2 (kv=0) holds nothing" "" "$(db "$C2")"
check "sync: the entry is the sibling's own, verbatim (ssid + nr)" \
	"$(cut -d' ' -f1-3 "$T/hap/$A5.own")" "$(grep "^$(bid "$A5") " "$T/hap/$A2.db")"
tick
check "sync again: nothing written (the entries are there)" "0 0" "$(grep -c '_NEIGHBOR [0-9a-f]' "$T/cmds") $(grep -c ' REMOVE_NEIGHBOR' "$T/cmds")"
# a changed nr (a channel change of 6g): written again to its 2 siblings only
own "$A6" one 83450e
tick
check "sync: a sibling's changed nr is written again, to its two siblings only" \
	"$(srt "$A2 SET_NEIGHBOR $(bid "$A6")" "$A5 SET_NEIGHBOR $(bid "$A6")")" \
	"$(grep ' SET_NEIGHBOR ' "$T/cmds" | cut -d' ' -f1-3 | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
# a BSS not running: skipped (no entry from it, none to it), no error
touch "$T/hap/$B5.down"; tick
check "sync: a BSS not answering: nothing written, nothing removed" "0" "$(grep -c '_NEIGHBOR [0-9a-f]' "$T/cmds")"
rm -f "$T/hap/$B5.down"
: > "$T/log"

# ---- 2. steering ----
# stations: RFC 7042 documentation MACs
SA=00:00:5e:00:53:1a SB=00:00:5e:00:53:1b SC=00:00:5e:00:53:1c SD=00:00:5e:00:53:1d SE=00:00:5e:00:53:1e SF=00:00:5e:00:53:1f
sta() {	# sta MAC SIGNAL RXBYTES TXBYTES
	printf 'Station %s (on x)\n\tinactive time:\t10 ms\n\trx bytes:\t%s\n\trx packets:\t10\n\ttx bytes:\t%s\n\ttx packets:\t10\n\tsignal:  \t%s [%s, %s] dBm\n\tsignal avg:\t%s [%s, %s] dBm\n' \
		"$1" "$3" "$4" "$(($2 + 1))" "$(($2 + 1))" "$(($2 + 1))" "$2" "$2" "$2"
}
echo 000008 > "$T/hap/sta.$SA"	# BSS transition: octet 2 bit 3
echo 0000f7 > "$T/hap/sta.$SB"	# every bit of octet 2 but bit 3
echo 000008 > "$T/hap/sta.$SC"; echo 000008 > "$T/hap/sta.$SD"; echo 000008 > "$T/hap/sta.$SE"; echo 000008 > "$T/hap/sta.$SF"
RXF=1000
fill() {	# the station dumps of one sample; F's traffic grows 100 kB per sample
	RXF=$((RXF + 100000))
	{ sta $SA -50 1000 1000; sta $SB -50 1000 1000; sta $SC -68 1000 1000; } > "$T/iw/$A2"
	sta $SD -40 1000 1000 > "$T/iw/$B2"
	{ sta $SE -75 5000 5000; sta $SF -75 "$RXF" 1000; } > "$T/iw/$A5"
}
reqs() { grep -c " BSS_TM_REQ $1" "$T/cmds"; }
fill; tick; s1="$(reqs $SA)"; fill; tick; s2="$(reqs $SA)"
check "upgrade: strong 2.4 GHz BTM station: no request after 1 and 2 samples" "0 0" "$s1 $s2"
fill; tick
check "upgrade: exactly one request at the 3rd sample" "1" "$(reqs $SA)"
want="$A2 BSS_TM_REQ $SA pref=1 abridged=1 valid_int=255 neighbor=$(bid "$A5"),0x0000008f,128,36,9,0301ff0603002a00 neighbor=$(bid "$A6"),0x0000008f,131,69,14,0301fe"
check "upgrade: the request (5gl then 6g, hostapd's own bssid_info/op class/channel/PHY, preference 255/254)" "$want" "$(grep " BSS_TM_REQ $SA" "$T/cmds")"
check "upgrade: one STEER line, stable format" "STEER kind=upgrade if=$A2 sta=$SA rssi=-50 n=3 target=$(bid "$A5") rc=OK" "$(grep "^STEER .*sta=$SA" "$T/log")"
check "upgrade: the non-BTM station B: no request, one STEER-SKIP no-btm" "0 STEER-SKIP reason=no-btm kind=upgrade if=$A2 sta=$SB rssi=-50 n=3" \
	"$(reqs $SB) $(grep "sta=$SB" "$T/log")"
check "upgrade: station C at -68 dBm (below -65): never counted" "0 0" "$(reqs $SC) $(grep -c "sta=$SC" "$T/log")"
check "steer=0 network 2: its strong BTM station D is never asked" "0 0" "$(grep -c "BSS_TM_REQ $SD" "$T/cmds") $(grep -c "sta=$SD" "$T/log")"
check "assist: weak idle E (5gl): not yet at the 3rd sample (the 1st set its byte baseline)" "0" "$(reqs $SE)"
fill; tick
check "assist: weak idle E: one request at the 4th sample (3 idle intervals)" "1" "$(reqs $SE)"
want="$A5 BSS_TM_REQ $SE pref=1 valid_int=255 neighbor=$(bid "$A2"),0x0000008f,81,1,7,0301ff neighbor=$(bid "$A6"),0x0000008f,131,69,14,0301fe"
check "assist: the request lists the siblings, 2.4 GHz preferred, not abridged" "$want" "$(grep " BSS_TM_REQ $SE" "$T/cmds")"
check "assist: the STEER line" "STEER kind=assist if=$A5 sta=$SE rssi=-75 n=3 target=$(bid "$A2") rc=OK" "$(grep "^STEER .*sta=$SE" "$T/log")"
check "assist: weak but busy F (160 kbit/s > 20): never asked" "0 0" "$(reqs $SF) $(grep -c "sta=$SF" "$T/log")"
# cooldown: A keeps its strong signal: samples 4..6 meet the policy again
fill; tick; fill; tick; c1=$(reqs $SA); fill; tick; c2=$(reqs $SA)
check "cooldown: no second request to A within 300 s" "0 0" "$c1 $c2"
check "cooldown: said once (STEER-SKIP reason=cooldown), the no-btm skip of B not repeated" "1 1" \
	"$(grep -c "^STEER-SKIP reason=cooldown kind=upgrade if=$A2 sta=$SA " "$T/log") $(grep -c "reason=no-btm.*sta=$SB" "$T/log")"
for i in 1 2 3 4 5 6 7 8 9 10; do fill; tick; done
check "cooldown: still nothing for A at +80 s" "1" "$(grep -c "^STEER .*sta=$SA" "$T/log")"
# control: once the 300 s passed, A is asked again
echo "$(( $(cut -d. -f1 "$T/uptime") + 300 )).00 1.00" > "$T/uptime"
fill; tick; fill; tick; fill; tick
check "cooldown control: after 300 s A is asked again (2 STEER lines)" "2" "$(grep -c "^STEER .*sta=$SA" "$T/log")"
check "never a disconnect: no DEAUTHENTICATE/DISASSOCIATE/disassoc_imminent anywhere" "0" \
	"$(cat "$T/cmds" "$T/log" | grep -ciE 'deauth|disassoc')"

# ---- 3. a BSS leaves the network: its entries are removed from the siblings ----
: > "$T/log"
mkplan "2g 5gl"
tick
check "remove: network 1 leaves 6g: its entry removed from $A2 and $A5 (2 REMOVE, OK)" \
	"$(srt "$A2 REMOVE_NEIGHBOR $I6" "$A5 REMOVE_NEIGHBOR $I6") 2" \
	"$(grep ' REMOVE_NEIGHBOR ' "$T/cmds" | cut -d' ' -f1-3 | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//') $(grep -c '^NBR remove .* rc=OK$' "$T/log")"
check "remove: $A2 holds exactly $A5 now; network 2 untouched" "$(bid "$A5")|$(bid "$B5")" "$(db "$A2")|$(db "$B2")"
# an entry this daemon did not write is never removed
echo "00:00:5e:00:53:99 ssid=78 nr=00005e00539900000000510107" >> "$T/hap/$A2.db"
tick
check "remove: an entry set by someone else stays" "0 yes" "$(grep -c ' REMOVE_NEIGHBOR ' "$T/cmds") $(grep -q '^00:00:5e:00:53:99 ' "$T/hap/$A2.db" && echo yes || echo no)"
# no kv network: the daemon does nothing
{ net 1 one password1 "2g 5gl" 1; } > "$T/nets"; GT_BE98_KV=1 $SH "$G" -n "$T/nets" -o "$T/run/gt-be98-wifi/gen" -s "$T/slots" -m "$M" 2> /dev/null
tick
check "no kv line in the plan: no hostapd command at all" "0" "$(wc -l < "$T/cmds" | tr -d ' ')"
check "usage: exit 2" 2 "$($SH "$S" bogus > /dev/null 2>&1; echo $?)"
# run: exits once its pid file does not name it
echo 1 > "$T/run/gt-be98-wifi-steer.pid"; : > "$T/log"
timeout 10 $SH "$S" run; r=$?
check "run: a pid file naming another pid: exits 0 at once, said" "0 1" "$r $(grep -c 'pid file names 1: exiting' "$T/log")"

if [ $fail = 0 ]; then echo "ALL OK ($n checks)"; else echo "FAILED"; fi
exit $fail
